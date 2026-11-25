use crate::{
    Hit, Model, ModelBackend, absolute, document_stamp_sql,
    model::{Role, Unencodable},
    open_write, read_document_stamp, row_hit,
};
use anyhow::{Context, Result, bail, ensure};
use rusqlite::{Connection, OptionalExtension, TransactionBehavior, params};
use std::{collections::HashMap, ops::Range, path::Path};

const CHUNK_CHARS: usize = 480;
const EARLIEST_BREAK: usize = 300;
const MAX_DOCUMENT_CHUNKS: usize = 128;
const MAX_EMBEDDED_CHUNKS: i64 = 50_000;
const MAX_VECTOR_BYTES: i64 = 128 * 1024 * 1024;
const MAX_BATCH: usize = 1000;

pub(super) const SCHEMA: &str = "
    CREATE TABLE IF NOT EXISTS semantic_state(
        singleton INTEGER PRIMARY KEY CHECK(singleton=1),
        model TEXT, dimensions INTEGER CHECK(dimensions BETWEEN 8 AND 4096),
        vectors INTEGER NOT NULL DEFAULT 0 CHECK(vectors>=0)
    );
    INSERT OR IGNORE INTO semantic_state(singleton) VALUES(1);
    CREATE TABLE IF NOT EXISTS semantic_document(
        document_id INTEGER PRIMARY KEY,
        prepared INTEGER NOT NULL DEFAULT 0
    );
    INSERT OR IGNORE INTO semantic_document(document_id) SELECT id FROM document;
    CREATE INDEX IF NOT EXISTS semantic_document_pending ON semantic_document(document_id) WHERE prepared=0;
    CREATE TABLE IF NOT EXISTS semantic_chunk(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        document_id INTEGER NOT NULL,
        start_byte INTEGER NOT NULL CHECK(start_byte>=0),
        end_byte INTEGER NOT NULL CHECK(end_byte>start_byte),
        vector BLOB,
        UNIQUE(document_id,start_byte)
    );
    CREATE INDEX IF NOT EXISTS semantic_pending ON semantic_chunk(id) WHERE vector IS NULL;
    CREATE TRIGGER IF NOT EXISTS semantic_vector_updated AFTER UPDATE OF vector ON semantic_chunk
        WHEN (old.vector IS NULL) != (new.vector IS NULL)
    BEGIN
        UPDATE semantic_state SET vectors = vectors + CASE WHEN new.vector IS NULL THEN -1 ELSE 1 END;
    END;
    CREATE TRIGGER IF NOT EXISTS semantic_vector_deleted AFTER DELETE ON semantic_chunk
        WHEN old.vector IS NOT NULL
    BEGIN
        UPDATE semantic_state SET vectors = vectors - 1;
    END;
    CREATE TRIGGER IF NOT EXISTS semantic_document_inserted AFTER INSERT ON document
    BEGIN
        INSERT INTO semantic_document(document_id) VALUES(new.id);
    END;
    CREATE TRIGGER IF NOT EXISTS semantic_document_deleted AFTER DELETE ON document
    BEGIN
        DELETE FROM semantic_document WHERE document_id=old.id;
        DELETE FROM semantic_chunk WHERE document_id=old.id;
    END;
    DELETE FROM embedding WHERE EXISTS(SELECT 1 FROM info WHERE key='model');
    DELETE FROM info WHERE key='model';
";

pub(super) const SKIP_SCHEMA: &str = "
    CREATE TABLE IF NOT EXISTS semantic_skip(chunk_id INTEGER PRIMARY KEY, model TEXT NOT NULL);
    CREATE TRIGGER IF NOT EXISTS semantic_skip_deleted AFTER DELETE ON semantic_chunk
    BEGIN
        DELETE FROM semantic_skip WHERE chunk_id=old.id;
    END;
";

pub(super) fn clear_model(conn: &Connection) -> Result<()> {
    conn.execute_batch(
        "UPDATE semantic_chunk SET vector=NULL WHERE vector IS NOT NULL;
         UPDATE semantic_state SET model=NULL, dimensions=NULL;",
    )?;
    Ok(())
}

pub(super) fn installed(conn: &Connection) -> rusqlite::Result<bool> {
    conn.query_row(
        "SELECT EXISTS(SELECT 1 FROM sqlite_schema WHERE type='table' AND name='semantic_state')",
        [],
        |r| r.get(0),
    )
}

struct State {
    model: Option<String>,
    dimensions: Option<i64>,
    vectors: i64,
}

impl State {
    fn read(conn: &Connection) -> Result<Self> {
        Ok(conn.query_row(
            "SELECT model, dimensions, vectors FROM semantic_state WHERE singleton=1",
            [],
            |r| {
                Ok(Self {
                    model: r.get(0)?,
                    dimensions: r.get(1)?,
                    vectors: r.get(2)?,
                })
            },
        )?)
    }

    fn check_model(&self, desired: &str, expected: Option<&str>) -> Result<()> {
        ensure!(
            self.model.as_deref() == Some(desired) || self.model.as_deref() == expected,
            "semantic index changed while embedding; restart the batch"
        );
        Ok(())
    }

    fn full(&self) -> bool {
        self.dimensions
            .is_some_and(|dims| dims > 0 && self.vectors >= vector_limit(dims))
    }
}

fn vector_limit(dimensions: i64) -> i64 {
    MAX_EMBEDDED_CHUNKS.min(MAX_VECTOR_BYTES / (dimensions * 4))
}

pub(super) fn add_status(conn: &Connection, status: &mut serde_json::Value) -> Result<()> {
    let (documents, chunks, limit) = if installed(conn)? {
        conn.query_row(
            "SELECT count(DISTINCT c.document_id), count(c.document_id),
                (SELECT dimensions FROM semantic_state WHERE singleton=1)
             FROM semantic_chunk c JOIN item i ON c.document_id=i.id
             WHERE i.availability<>'unverified' AND c.vector IS NOT NULL",
            [],
            |r| {
                let documents = r.get::<_, i64>(0)?;
                let chunks = r.get::<_, i64>(1)?;
                let dimensions = r.get::<_, Option<i64>>(2)?.filter(|dims| *dims > 0);
                Ok((documents, chunks, dimensions.map(vector_limit)))
            },
        )?
    } else {
        (0, 0, None)
    };
    status["embeddings"] = documents.into();
    status["embedded_chunks"] = chunks.into();
    status["embedding_chunk_limit"] = limit.into();
    Ok(())
}

pub fn embed(database: &Path, model: &Model, max: usize) -> Result<usize> {
    embed_with_backend(database, ModelBackend::Helper(model), max)
}

pub fn embed_with_backend(database: &Path, model: ModelBackend<'_>, max: usize) -> Result<usize> {
    Ok(embed_batch(database, model, max)?.new_embeddings)
}

#[derive(Default, serde::Serialize)]
pub struct EmbedBatch {
    pub new_embeddings: usize,
    pub skipped_chunks: usize,
    pub has_more: bool,
}

pub fn embed_batch(database: &Path, model: ModelBackend<'_>, max: usize) -> Result<EmbedBatch> {
    let (mut conn, _lease) = open_write(&absolute(database)?, false)?;
    let mut encoder = model.connect()?;
    let signature = encoder.signature().to_owned();
    let mut expected = State::read(&conn)?.model;
    let mut report = EmbedBatch::default();
    let mut prepared = 0;
    let mut attempted = 0;
    let mut unencodable = 0;
    let max = max.clamp(1, MAX_BATCH);
    let extra_budget = max.max(32);
    while attempted < max && unencodable < extra_budget {
        let state = State::read(&conn)?;
        state.check_model(&signature, expected.as_deref())?;
        let reuse = state.model.as_deref() == Some(&signature);
        if reuse && state.full() {
            break;
        }
        let Some((id, text)) = next_chunk(&conn, reuse, &signature)? else {
            if prepared >= extra_budget || !prepare_next_document(&mut conn)? {
                break;
            }
            prepared += 1;
            continue;
        };
        // Save each vector and unencodable input independently without
        // holding a SQLite writer lock while the model computes.
        let vector = match encoder.encode(Role::Passage, &text) {
            Ok(vector) => vector,
            Err(error) if error.is::<Unencodable>() => {
                report.skipped_chunks += save_skip(&mut conn, id, &signature, expected.as_deref())?;
                unencodable += 1;
                continue;
            }
            Err(error) => {
                return Err(error).with_context(|| {
                    format!(
                        "compute next semantic chunk ({} saved in this batch)",
                        report.new_embeddings
                    )
                });
            }
        };
        attempted += 1;
        if save_vector(&mut conn, id, &vector, &signature, expected.as_deref())? {
            expected = Some(signature.clone());
            report.new_embeddings += 1;
        }
    }
    let state = State::read(&conn)?;
    state.check_model(&signature, expected.as_deref())?;
    let reuse = state.model.as_deref() == Some(&signature);
    if !(reuse && state.full()) {
        report.has_more = next_chunk(&conn, reuse, &signature)?.is_some()
            || conn.query_row(
                "SELECT EXISTS(SELECT 1 FROM semantic_document p JOIN item i ON i.id=p.document_id
                   WHERE p.prepared=0 AND i.availability<>'unverified')",
                [],
                |row| row.get(0),
            )?;
    }
    Ok(report)
}

fn next_chunk(conn: &Connection, reuse: bool, signature: &str) -> Result<Option<(i64, String)>> {
    const SELECT: &str = "SELECT c.id,
               CAST(substr(CAST(d.body AS BLOB), c.start_byte+1, c.end_byte-c.start_byte) AS TEXT)
         FROM semantic_chunk c JOIN document d ON d.id=c.document_id JOIN item i ON i.id=d.id
         WHERE i.availability<>'unverified'
           AND NOT EXISTS(SELECT 1 FROM semantic_skip s WHERE s.chunk_id=c.id AND s.model=?1)";
    let vector = if reuse { " AND c.vector IS NULL" } else { "" };
    let sql = format!("{SELECT}{vector} ORDER BY c.id LIMIT 1");
    Ok(conn
        .prepare_cached(&sql)?
        .query_row([signature], |r| Ok((r.get(0)?, r.get(1)?)))
        .optional()?)
}

fn save_skip(
    conn: &mut Connection,
    id: i64,
    signature: &str,
    expected: Option<&str>,
) -> Result<usize> {
    let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let state = State::read(&tx)?;
    state.check_model(signature, expected)?;
    let new = tx.execute(
        "INSERT INTO semantic_skip (chunk_id, model)
         SELECT c.id,?2 FROM semantic_chunk c JOIN item i ON i.id=c.document_id
         WHERE c.id=?1 AND i.availability<>'unverified' AND (c.vector IS NULL OR NOT ?3)
         ON CONFLICT(chunk_id) DO UPDATE SET model=excluded.model
         WHERE model<>excluded.model",
        params![id, signature, state.model.as_deref() == Some(signature)],
    )?;
    tx.commit()?;
    Ok(new)
}

fn prepare_next_document(conn: &mut Connection) -> Result<bool> {
    let document: Option<(i64, String)> = conn
        .prepare_cached(
            "SELECT d.id,d.body FROM semantic_document p
             JOIN document d ON d.id=p.document_id JOIN item i ON i.id=d.id
             WHERE p.prepared=0 AND i.availability<>'unverified'
             ORDER BY p.document_id LIMIT 1",
        )?
        .query_row([], |r| Ok((r.get(0)?, r.get(1)?)))
        .optional()?;
    let Some((id, body)) = document else {
        return Ok(false);
    };
    let ranges = chunk_ranges(&body);
    let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let new = tx
        .prepare_cached(
            "UPDATE semantic_document SET prepared=1 WHERE document_id=?1 AND prepared=0
         AND EXISTS(SELECT 1 FROM document d JOIN item i USING(id)
                    WHERE d.id=?1 AND d.body=?2 AND i.availability<>'unverified')",
        )?
        .execute(params![id, body])?;
    if new != 0 {
        let mut insert = tx.prepare_cached(
            "INSERT INTO semantic_chunk(document_id,start_byte,end_byte) VALUES(?,?,?)",
        )?;
        for range in ranges {
            insert.execute(params![id, range.start as i64, range.end as i64])?;
        }
    }
    tx.commit()?;
    Ok(true)
}

fn save_vector(
    conn: &mut Connection,
    id: i64,
    vector: &[f32],
    signature: &str,
    expected: Option<&str>,
) -> Result<bool> {
    let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let state = State::read(&tx)?;
    state.check_model(signature, expected)?;
    let candidate: bool = tx
        .prepare_cached(
            "SELECT EXISTS(SELECT 1 FROM semantic_chunk c JOIN item i ON i.id=c.document_id
          WHERE c.id=? AND i.availability<>'unverified')",
        )?
        .query_row([id], |r| r.get(0))?;
    if !candidate {
        // A document change deletes its chunks. AUTOINCREMENT prevents a
        // finishing helper from attaching its vector to a replacement chunk.
        return Ok(false);
    }
    let dims = vector.len() as i64;
    if state.model.as_deref() != Some(signature) {
        clear_model(&tx)?;
        tx.execute(
            "UPDATE semantic_state SET model=?,dimensions=?",
            params![signature, dims],
        )?;
    } else {
        ensure!(
            state.dimensions == Some(dims),
            "local model changed embedding dimensions"
        );
        if state.full() {
            return Ok(false);
        }
    }
    let bytes: Vec<u8> = vector.iter().flat_map(|n| n.to_le_bytes()).collect();
    let changed = tx.execute(
        "UPDATE semantic_chunk SET vector=? WHERE id=? AND vector IS NULL",
        params![bytes, id],
    )? != 0;
    if changed {
        tx.execute(
            "DELETE FROM semantic_skip WHERE chunk_id=? AND model=?",
            params![id, signature],
        )?;
    }
    tx.commit()?;
    Ok(changed)
}

pub(super) fn search(
    conn: &Connection,
    query: &str,
    limit: usize,
    model: ModelBackend<'_>,
) -> Result<Vec<Hit>> {
    let mut encoder = model.connect()?;
    let signature = encoder.signature().to_owned();
    let validate = |conn: &Connection| -> Result<State> {
        if !installed(conn)? {
            bail!("no paragraph embeddings: run lumen embed first");
        }
        let state = State::read(conn)?;
        match state.model.as_deref() {
            Some(saved) if saved == signature => Ok(state),
            Some(_) => bail!("model or language changed: build embeddings first"),
            None => bail!("no paragraph embeddings: run lumen embed first"),
        }
    };
    validate(conn)?;
    let vector = encoder.encode(Role::Query, query)?;
    // Read scores and original snippets from the same snapshot while watch
    // may replace documents in the background.
    let tx = conn
        .is_autocommit()
        .then(|| conn.unchecked_transaction())
        .transpose()?;
    let snapshot = tx.as_deref().unwrap_or(conn);
    let state = validate(snapshot)?;
    ensure!(
        state.dimensions == Some(vector.len() as i64),
        "stored and query embedding dimensions differ"
    );
    let mut best = HashMap::<i64, (f32, i64, String)>::new();
    {
        let mut statement = snapshot.prepare_cached(
            "SELECT c.document_id, c.id, i.path, c.vector FROM semantic_chunk c
             JOIN item i ON i.id=c.document_id WHERE i.availability<>'unverified' AND c.vector IS NOT NULL",
        )?;
        let mut rows = statement.query([])?;
        while let Some(row) = rows.next()? {
            let bytes = row.get_ref(3)?.as_blob()?;
            ensure!(
                bytes.len() == vector.len() * 4,
                "invalid stored paragraph vector"
            );
            let score = bytes
                .chunks_exact(4)
                .zip(&vector)
                .map(|(word, q)| f32::from_le_bytes(word.try_into().expect("four bytes")) * q)
                .sum::<f32>();
            if score.is_finite() && encoder.includes(score) {
                let document = row.get(0)?;
                let id: i64 = row.get(1)?;
                if best.get(&document).is_none_or(|(prior, prior_id, _)| {
                    score > *prior || score == *prior && id < *prior_id
                }) {
                    best.insert(document, (score, id, row.get(2)?));
                }
            }
        }
    }
    let mut ranked: Vec<_> = best.into_values().collect();
    ranked.sort_unstable_by(|a, b| b.0.total_cmp(&a.0).then_with(|| a.2.cmp(&b.2)));
    let mut hits = Vec::new();
    {
        let (stamp, state_join) = document_stamp_sql(snapshot)?;
        let sql = format!(
            "SELECT i.path,i.display,i.kind,i.availability,
               CAST(substr(CAST(d.body AS BLOB), c.start_byte+1, c.end_byte-c.start_byte) AS TEXT),
               {stamp} AS document_stamp
             FROM semantic_chunk c JOIN document d ON d.id=c.document_id JOIN item i ON i.id=d.id
             {state_join} WHERE c.id=?"
        );
        let mut hit = snapshot.prepare_cached(&sql)?;
        for (score, id, _) in ranked.into_iter().take(limit) {
            hits.push(hit.query_row([id], |r| {
                let mut record = row_hit(r, encoder.match_reason())?;
                record.snippet = r.get(4)?;
                record.document_stamp = read_document_stamp(r)?;
                record.score = Some(score.into());
                Ok(record)
            })?);
        }
    }
    if let Some(tx) = tx {
        tx.commit()?;
    }
    Ok(hits)
}

fn chunk_ranges(body: &str) -> Vec<Range<usize>> {
    let mut ranges = Vec::new();
    let mut offset = 0;
    let mut paragraph_start = 0;
    for line in body.split_inclusive('\n') {
        if line.trim().is_empty() {
            split_paragraph(&body[paragraph_start..offset], paragraph_start, &mut ranges);
            paragraph_start = offset + line.len();
        }
        offset += line.len();
    }
    split_paragraph(&body[paragraph_start..], paragraph_start, &mut ranges);
    if ranges.len() <= MAX_DOCUMENT_CHUNKS {
        return ranges;
    }
    // For very long documents, distribute the budget through the entire
    // document, including the last chunk.
    (0..MAX_DOCUMENT_CHUNKS)
        .map(|slot| ranges[slot * (ranges.len() - 1) / (MAX_DOCUMENT_CHUNKS - 1)].clone())
        .collect()
}

fn split_paragraph(mut text: &str, mut offset: usize, ranges: &mut Vec<Range<usize>>) {
    while !text.is_empty() {
        let mut boundary = text.len();
        let mut sentence = None;
        let mut word = None;
        for (count, (byte, ch)) in text.char_indices().enumerate() {
            if count == CHUNK_CHARS {
                boundary = sentence.or(word).unwrap_or(byte);
                break;
            }
            if count + 1 >= EARLIEST_BREAK {
                let after = byte + ch.len_utf8();
                if matches!(ch, '.' | '!' | '?' | '。' | '！' | '？' | '；') {
                    sentence = Some(after);
                } else if ch.is_whitespace() {
                    word = Some(after);
                }
            }
        }
        let chunk = &text[..boundary];
        let end = chunk.trim_end().len();
        let start = chunk.len() - chunk.trim_start().len();
        if start < end {
            ranges.push(offset + start..offset + end);
        }
        offset += boundary;
        text = &text[boundary..];
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn long_documents_sample_their_tail_at_unicode_boundaries() {
        let text = (0..1200)
            .map(|i| format!("第{i}段落。"))
            .collect::<Vec<_>>()
            .join("\n\n");
        let ranges = chunk_ranges(&text);
        assert_eq!(ranges.len(), MAX_DOCUMENT_CHUNKS);
        assert_eq!(&text[ranges[0].clone()], "第0段落。");
        assert_eq!(&text[ranges[ranges.len() - 1].clone()], "第1199段落。");
        assert!(ranges.iter().all(|range| text.get(range.clone()).is_some()));

        let single_paragraph = "句".repeat(CHUNK_CHARS * 3 + 1);
        let spans = chunk_ranges(&single_paragraph);
        assert_eq!(spans.len(), 4);
        assert_eq!(
            spans.iter().map(|r| r.len()).sum::<usize>(),
            single_paragraph.len()
        );
        assert_eq!(vector_limit(512), MAX_EMBEDDED_CHUNKS);
        assert_eq!(vector_limit(4096), MAX_VECTOR_BYTES / (4096 * 4));
    }
}
