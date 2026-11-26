use crate::{
    Hit, Model, ModelBackend, PdfHelperPolicy, Scope, absolute,
    diagnose::read_snapshot,
    document_stamp_sql, gemma,
    index::{DocumentKind, in_explicit_content_root},
    model::{Role, Unencodable},
    open_write, read_document_stamp, row_hit, saved_index_scope,
    vector::{Matrix, MatrixCache, adaptive_floor, pack},
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

// Additive to the legacy BGE/helper slot. The versioned store allows upgrades
// without changing the legacy vectors or stranding them on rollback.
pub(super) const VERSIONED_SCHEMA: &str = "
    CREATE TABLE IF NOT EXISTS semantic_vector(
        model TEXT NOT NULL, chunk_id INTEGER NOT NULL,
        vector BLOB, PRIMARY KEY(model,chunk_id)
    ) WITHOUT ROWID;
    CREATE INDEX IF NOT EXISTS semantic_vector_chunk ON semantic_vector(chunk_id);
    CREATE TABLE IF NOT EXISTS semantic_vector_count(
        model TEXT PRIMARY KEY, vectors INTEGER NOT NULL CHECK(vectors>=0)
    ) WITHOUT ROWID;
    CREATE TRIGGER IF NOT EXISTS semantic_versioned_chunk_deleted AFTER DELETE ON semantic_chunk
    BEGIN
        DELETE FROM semantic_vector WHERE chunk_id=old.id;
    END;
    CREATE TRIGGER IF NOT EXISTS semantic_versioned_vector_inserted AFTER INSERT ON semantic_vector
        WHEN new.vector IS NOT NULL
    BEGIN
        INSERT INTO semantic_vector_count VALUES(new.model,1)
            ON CONFLICT(model) DO UPDATE SET vectors=vectors+1;
    END;
    CREATE TRIGGER IF NOT EXISTS semantic_versioned_vector_deleted AFTER DELETE ON semantic_vector
        WHEN old.vector IS NOT NULL
    BEGIN
        UPDATE semantic_vector_count SET vectors=vectors-1 WHERE model=old.model;
    END;
";

#[derive(serde::Serialize)]
pub struct GemmaCoverage {
    pub documents_enabled: bool,
    pub embedded_chunks: i64,
    pub skipped_chunks: i64,
    pub pending: bool,
    pub limited: bool,
    pub chunk_limit: i64,
}

impl GemmaCoverage {
    pub fn searchable(&self) -> bool {
        self.documents_enabled && self.embedded_chunks > 0
    }
}

pub fn gemma_coverage(conn: &Connection) -> Result<GemmaCoverage> {
    let tx = conn
        .is_autocommit()
        .then(|| conn.unchecked_transaction())
        .transpose()?;
    let coverage = read_gemma_coverage(tx.as_deref().unwrap_or(conn))?;
    if let Some(tx) = tx {
        tx.commit()?;
    }
    Ok(coverage)
}

fn read_gemma_coverage(conn: &Connection) -> Result<GemmaCoverage> {
    let mut coverage = GemmaCoverage {
        documents_enabled: documents_enabled(conn)?,
        embedded_chunks: 0,
        skipped_chunks: 0,
        pending: false,
        limited: false,
        chunk_limit: gemma_limit(),
    };
    if !coverage.documents_enabled {
        return Ok(coverage);
    }
    // Provider documents are created only within explicit content roots and
    // pruned on scope changes, just like the rest of the document store.
    if !has_gemma_store(conn)? {
        coverage.pending = conn.query_row(
            "SELECT EXISTS(SELECT 1 FROM document JOIN item USING(id) WHERE availability IN ('local','provider_metadata_only'))",
            [],
            |row| row.get(0),
        )?;
        return Ok(coverage);
    }
    (coverage.embedded_chunks, coverage.skipped_chunks) = conn.prepare_cached(&format!(
        "SELECT count(*) FILTER (WHERE {GEMMA_VECTOR}), count(*) FILTER (WHERE v.vector IS NULL) {GEMMA_LIVE}"
    ))?.query_row(params![gemma::ID, GEMMA_VECTOR_BYTES], |row| Ok((row.get(0)?, row.get(1)?)))?;
    coverage.pending = gemma_pending(conn)?;
    coverage.limited = coverage.pending && gemma_count(conn)? >= coverage.chunk_limit;
    Ok(coverage)
}

fn has_gemma_store(conn: &Connection) -> Result<bool> {
    Ok(conn
        .prepare_cached(
            "SELECT count(*)=2 FROM sqlite_schema
         WHERE type='table' AND name IN ('semantic_vector','semantic_chunk')",
        )?
        .query_row([], |row| row.get(0))?)
}

fn gemma_searchable(conn: &Connection) -> Result<bool> {
    read_snapshot(conn, read_gemma_searchable)
}

fn read_gemma_searchable(conn: &Connection) -> Result<bool> {
    Ok(documents_enabled(conn)?
        && has_gemma_store(conn)?
        && conn
            .prepare_cached(&format!(
                "SELECT EXISTS(SELECT 1 {GEMMA_LIVE} AND {GEMMA_VECTOR})"
            ))?
            .query_row(params![gemma::ID, GEMMA_VECTOR_BYTES], |row| {
                row.get::<_, bool>(0)
            })?)
}

const GEMMA_VECTOR_BYTES: i64 = (gemma::DIMENSIONS * size_of::<f32>()) as i64;

const GEMMA_LIVE: &str = "FROM semantic_vector v JOIN semantic_chunk c ON c.id=v.chunk_id
    JOIN item i ON i.id=c.document_id JOIN document_state ds ON ds.id=c.document_id
    WHERE v.model=?1 AND i.availability IN ('local','provider_metadata_only')";
const GEMMA_VECTOR: &str = "typeof(v.vector)='blob' AND length(v.vector) IN (?2/2,?2)";
const GEMMA_MIN_COSINE: f32 = f32::MIN_POSITIVE;
const GEMMA_Z_THRESHOLD: f64 = 1.0;

fn documents_enabled(conn: &Connection) -> Result<bool> {
    let saved: Option<String> = conn
        .query_row("SELECT value FROM info WHERE key='scope'", [], |row| {
            row.get(0)
        })
        .optional()?;
    Ok(saved
        .as_deref()
        .map(serde_json::from_str::<crate::Scope>)
        .transpose()?
        .is_some_and(|scope| scope.documents))
}

const GEMMA_QUEUE: &str = "FROM semantic_chunk c JOIN item i ON i.id=c.document_id
    JOIN document_state ds ON ds.id=c.document_id WHERE i.availability IN ('local','provider_metadata_only') AND NOT EXISTS
       (SELECT 1 FROM semantic_vector v INDEXED BY semantic_vector_chunk WHERE v.model=?1 AND v.chunk_id=c.id)";

fn gemma_pending(conn: &Connection) -> Result<bool> {
    Ok(conn
        .prepare_cached(&format!(
            "SELECT EXISTS(SELECT 1 {GEMMA_QUEUE}) OR EXISTS(
            SELECT 1 FROM semantic_document p JOIN item i ON i.id=p.document_id
            JOIN document_state ds ON ds.id=p.document_id
            WHERE p.prepared=0 AND i.availability IN ('local','provider_metadata_only'))"
        ))?
        .query_row([gemma::ID], |row| row.get(0))?)
}

fn gemma_count(conn: &Connection) -> Result<i64> {
    Ok(conn
        .prepare_cached(
            "SELECT coalesce((SELECT vectors FROM semantic_vector_count WHERE model=?1),0)",
        )?
        .query_row([gemma::ID], |row| row.get(0))?)
}

pub(super) fn diagnose_gemma(conn: &Connection, document: i64) -> Result<crate::diagnose::Reason> {
    use crate::diagnose::Reason;
    if !has_gemma_store(conn)? {
        return Ok(Reason::PendingGemma);
    }
    let (total, indexed, skipped, marked): (i64, i64, i64, i64) = conn
        .prepare_cached(&format!(
            "SELECT count(c.id),count(*) FILTER (WHERE {GEMMA_VECTOR}),
            count(v.chunk_id) FILTER (WHERE v.vector IS NULL),count(v.chunk_id)
         FROM semantic_chunk c LEFT JOIN semantic_vector v ON v.chunk_id=c.id AND v.model=?1
         WHERE c.document_id=?3"
        ))?
        .query_row(params![gemma::ID, GEMMA_VECTOR_BYTES, document], |r| {
            Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?))
        })?;
    if indexed > 0 {
        return Ok(Reason::Indexed);
    }
    if marked > skipped {
        return Ok(Reason::Unknown);
    }
    let prepared: Option<bool> = conn
        .prepare_cached("SELECT prepared FROM semantic_document WHERE document_id=?1")?
        .query_row([document], |r| r.get(0))
        .optional()?;
    if prepared == Some(true) && total == skipped {
        return Ok(Reason::GemmaSkipped);
    }
    if gemma_count(conn)? >= gemma_limit() {
        return Ok(Reason::GemmaLimited);
    }
    Ok(Reason::PendingGemma)
}

fn gemma_limit() -> i64 {
    vector_limit(gemma::DIMENSIONS as i64)
}

fn embed_gemma(conn: &mut Connection, model: &crate::GemmaModel, max: usize) -> Result<EmbedBatch> {
    ensure!(
        documents_enabled(conn)?,
        "Gemma requires explicit document indexing scope"
    );
    let mut report = EmbedBatch::default();
    if gemma_count(conn)? >= gemma_limit() || !gemma_pending(conn)? {
        return Ok(report);
    }
    let mut encoder = ModelBackend::Gemma(model).connect()?;
    let max = max.clamp(1, MAX_BATCH);
    let mut prepared = 0;
    let mut after = 0_i64;
    for _ in 0..max {
        if !documents_enabled(conn)? || gemma_count(conn)? >= gemma_limit() {
            break;
        }
        let next = loop {
            let row: Option<(i64, String)> = conn.prepare_cached(&format!(
                "WITH next AS (SELECT c.id,c.document_id,c.start_byte,c.end_byte {GEMMA_QUEUE} AND c.id>?2 ORDER BY c.id LIMIT 1)
                 SELECT c.id, CAST(substr(CAST(d.body AS BLOB),c.start_byte+1,c.end_byte-c.start_byte) AS TEXT)
                 FROM next c JOIN document d ON d.id=c.document_id"
            ))?.query_row(params![gemma::ID, after], |r| Ok((r.get(0)?, r.get(1)?))).optional()?;
            if row.is_some() || prepared >= max.max(32) || !prepare_next_document(conn, true)? {
                break row;
            }
            prepared += 1;
        };
        let Some((id, text)) = next else {
            break;
        };
        after = id;
        let vector = match encoder.encode(Role::Passage, &text) {
            Ok(vector) => Some(pack(&vector)),
            Err(error) if error.is::<Unencodable>() => None,
            Err(error) => return Err(error).context("compute next Gemma document chunk"),
        };
        let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
        if !documents_enabled(&tx)? || gemma_count(&tx)? >= gemma_limit() {
            break;
        }
        let saved = tx.execute(
            "INSERT OR IGNORE INTO semantic_vector(model,chunk_id,vector)
             SELECT ?1,c.id,?3 FROM semantic_chunk c JOIN item i ON i.id=c.document_id
             JOIN document_state ds ON ds.id=c.document_id WHERE c.id=?2 AND i.availability IN ('local','provider_metadata_only')",
            params![gemma::ID, id, vector],
        )?;
        tx.commit()?;
        if vector.is_some() {
            report.new_embeddings += saved;
        } else {
            report.skipped_chunks += saved;
        }
    }
    report.has_more =
        documents_enabled(conn)? && gemma_count(conn)? < gemma_limit() && gemma_pending(conn)?;
    Ok(report)
}

pub(super) enum GemmaQuery {
    Worker(gemma::GemmaWorker),
    #[cfg(test)]
    Fixture(Box<dyn FnMut() -> Vec<f32> + Send>),
}

impl GemmaQuery {
    pub fn encode(&mut self, text: &str) -> Result<Vec<f32>> {
        match self {
            Self::Worker(worker) => worker.encode(Role::Query, text),
            #[cfg(test)]
            Self::Fixture(encode) => Ok(encode()),
        }
    }
}

pub struct GemmaSearchSession {
    conn: Connection,
    worker: GemmaQuery,
    matrix: MatrixCache<Paragraph>,
}

impl GemmaSearchSession {
    pub fn open(database: &Path, model: &crate::GemmaModel) -> Result<Self> {
        let conn = crate::open_read(database)?;
        ensure!(
            gemma_searchable(&conn)?,
            "no current Gemma paragraph embeddings: run lumen embed --gemma first"
        );
        let mut worker = model.start()?;
        worker.probe()?;
        ensure!(
            gemma_searchable(&conn)?,
            "Gemma document coverage changed while starting the runtime"
        );
        Ok(Self {
            conn,
            worker: GemmaQuery::Worker(worker),
            matrix: MatrixCache::default(),
        })
    }

    pub fn search(&mut self, query: &str, limit: usize) -> Result<Vec<Hit>> {
        let query = query.trim();
        if query.is_empty() || query.len() > 512 || !crate::query_allows_semantic(query) {
            return Ok(Vec::new());
        }
        let mut hits = search_gemma(
            &self.conn,
            query,
            limit.clamp(1, 100),
            &mut self.worker,
            &mut self.matrix,
        )?;
        hits.retain(|hit| !crate::external::is_external(Path::new(&hit.path)));
        Ok(hits)
    }
}

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
    // Bound the decoded matrix, including catalogs that still store binary32.
    MAX_EMBEDDED_CHUNKS.min(MAX_VECTOR_BYTES / (dimensions * 4))
}

pub(super) fn add_status(conn: &Connection, status: &mut serde_json::Value) -> Result<()> {
    let (documents, chunks, limit) = if installed(conn)? {
        conn.query_row(
            "SELECT count(DISTINCT c.document_id), count(c.document_id),
                (SELECT dimensions FROM semantic_state WHERE singleton=1)
             FROM semantic_chunk c JOIN item i ON c.document_id=i.id
             WHERE i.availability IN ('local','provider_metadata_only') AND c.vector IS NOT NULL",
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
    status["gemma"] = serde_json::to_value(gemma_coverage(conn)?)?;
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
    if matches!(model, ModelBackend::Gemma(_)) {
        ensure!(
            crate::open_read(database).and_then(|conn| documents_enabled(&conn))?,
            "Gemma requires explicit document indexing scope"
        );
    }
    let (mut conn, _lease) = open_write(&absolute(database)?, false)?;
    if let ModelBackend::Gemma(model) = model {
        return embed_gemma(&mut conn, model, max);
    }
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
            if prepared >= extra_budget || !prepare_next_document(&mut conn, false)? {
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
                   WHERE p.prepared=0 AND i.availability IN ('local','provider_metadata_only'))",
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
         WHERE i.availability IN ('local','provider_metadata_only')
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
         WHERE c.id=?1 AND i.availability IN ('local','provider_metadata_only') AND (c.vector IS NULL OR NOT ?3)
         ON CONFLICT(chunk_id) DO UPDATE SET model=excluded.model
         WHERE model<>excluded.model",
        params![id, signature, state.model.as_deref() == Some(signature)],
    )?;
    tx.commit()?;
    Ok(new)
}

fn prepare_next_document(conn: &mut Connection, require_stamp: bool) -> Result<bool> {
    let document: Option<(i64, String)> = conn
        .prepare_cached(
            "SELECT d.id,d.body FROM semantic_document p
             JOIN document d ON d.id=p.document_id JOIN item i ON i.id=d.id
             WHERE p.prepared=0 AND i.availability IN ('local','provider_metadata_only')
             AND (NOT ?1 OR EXISTS(SELECT 1 FROM document_state ds WHERE ds.id=p.document_id))
             ORDER BY p.document_id LIMIT 1",
        )?
        .query_row([require_stamp], |r| Ok((r.get(0)?, r.get(1)?)))
        .optional()?;
    let Some((id, body)) = document else {
        return Ok(false);
    };
    let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let new = tx
        .prepare_cached(
            "UPDATE semantic_document SET prepared=1 WHERE document_id=?1 AND prepared=0
         AND EXISTS(SELECT 1 FROM document d JOIN item i USING(id)
                    WHERE d.id=?1 AND d.body=?2 AND i.availability IN ('local','provider_metadata_only')
                    AND (NOT ?3 OR EXISTS(SELECT 1 FROM document_state ds WHERE ds.id=d.id)))",
        )?
        .execute(params![id, body, require_stamp])?;
    if new != 0 {
        let pages = crate::content::pages(&tx, id)?;
        let ranges = if pages.is_empty() {
            chunk_ranges(&body)
        } else {
            let ranges = pages
                .iter()
                .filter_map(|p| body.get(p.start..p.end).map(|text| (p.start, text)))
                .flat_map(|(start, text)| {
                    chunk_ranges(text)
                        .into_iter()
                        .map(move |r| (r.start + start)..(r.end + start))
                })
                .collect();
            sample_ranges(ranges)
        };
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
          WHERE c.id=? AND i.availability IN ('local','provider_metadata_only'))",
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
    let bytes = pack(vector);
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
    if let ModelBackend::Gemma(model) = model {
        ensure!(
            // Preflight before starting the model. Only the ranking snapshot
            // authorizes hits; coverage may change during inference.
            read_gemma_searchable(conn)?,
            "no current Gemma paragraph embeddings: run lumen embed --gemma first"
        );
        return search_gemma(
            conn,
            query,
            limit,
            &mut GemmaQuery::Worker(model.start()?),
            &mut MatrixCache::default(),
        );
    }
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
    read_snapshot(conn, |snapshot| {
        let Some(scope) = saved_index_scope(snapshot)?.filter(|scope| scope.documents) else {
            return Ok(Vec::new());
        };
        let state = validate(snapshot)?;
        ensure!(
            state.dimensions == Some(vector.len() as i64),
            "stored and query embedding dimensions differ"
        );
        let matrix = load_paragraphs(snapshot, vector.len(), LEGACY, [], |path| {
            paragraph_path_allowed(&scope, path)
        })?;
        rank(
            snapshot,
            &matrix,
            matrix.scores(&vector),
            limit,
            encoder.match_reason(),
            |score| encoder.includes(score),
        )
    })
}

fn search_gemma(
    conn: &Connection,
    query: &str,
    limit: usize,
    worker: &mut GemmaQuery,
    matrix: &mut MatrixCache<Paragraph>,
) -> Result<Vec<Hit>> {
    let vector = match worker.encode(query) {
        Ok(vector) => vector,
        Err(error) if error.is::<Unencodable>() => return Ok(Vec::new()),
        Err(error) => return Err(error),
    };
    read_snapshot(conn, |snapshot| {
        rank_gemma(snapshot, &vector, limit, matrix)
    })
}

const LEGACY: &str = "SELECT c.document_id, c.id, i.path, c.vector FROM semantic_chunk c
    JOIN item i ON i.id=c.document_id WHERE i.availability IN ('local','provider_metadata_only') AND c.vector IS NOT NULL";

struct Paragraph {
    document: i64,
    chunk: i64,
    path: Box<str>,
}

fn load_paragraphs(
    snapshot: &Connection,
    dims: usize,
    sql: &str,
    parameters: impl rusqlite::Params,
    allows: impl Fn(&Path) -> bool,
) -> Result<Matrix<Paragraph>> {
    let mut matrix = Matrix::new(dims);
    let mut statement = snapshot.prepare_cached(sql)?;
    let mut rows = statement.query(parameters)?;
    while let Some(row) = rows.next()? {
        let path = row.get_ref(2)?.as_str()?;
        if !allows(Path::new(path)) {
            continue;
        }
        let meta = Paragraph {
            document: row.get(0)?,
            chunk: row.get(1)?,
            path: path.into(),
        };
        ensure!(
            matrix.push(meta, row.get_ref(3)?.as_blob()?),
            "invalid stored paragraph vector"
        );
    }
    Ok(matrix)
}

fn paragraph_path_allowed(scope: &Scope, path: &Path) -> bool {
    !crate::external::is_external(path)
        && scope.roots.iter().any(|root| path.starts_with(root))
        && scope.allows(path)
        && (scope.content_roots.is_none() || in_explicit_content_root(scope, path))
        && DocumentKind::for_path(path).is_some_and(|kind| match kind {
            DocumentKind::Image => scope.image_ocr,
            DocumentKind::Pdf => {
                scope.pdf_helper.is_some()
                    || scope.pdf_helper_policy == Some(PdfHelperPolicy::Bundled)
            }
            _ => true,
        })
}

fn rank_gemma(
    snapshot: &Connection,
    query: &[f32],
    limit: usize,
    cache: &mut MatrixCache<Paragraph>,
) -> Result<Vec<Hit>> {
    let matrix = cache.get(snapshot, |snapshot| {
        let Some(scope) = saved_index_scope(snapshot)?.filter(|scope| scope.documents) else {
            return Ok(Matrix::new(gemma::DIMENSIONS));
        };
        if !has_gemma_store(snapshot)? {
            return Ok(Matrix::new(gemma::DIMENSIONS));
        }
        load_paragraphs(
            snapshot,
            gemma::DIMENSIONS,
            &format!("SELECT c.document_id,c.id,i.path,v.vector {GEMMA_LIVE} AND {GEMMA_VECTOR} AND i.kind='file'"),
            params![gemma::ID, GEMMA_VECTOR_BYTES],
            |path| paragraph_path_allowed(&scope, path),
        )
    })?;
    let scores: Vec<_> = matrix.scores(query).collect();
    let floor = adaptive_floor(&scores, GEMMA_MIN_COSINE, GEMMA_Z_THRESHOLD);
    rank(
        snapshot,
        matrix,
        scores,
        limit,
        "semantic_candidate",
        |score| f64::from(score) >= floor,
    )
}

fn rank(
    snapshot: &Connection,
    matrix: &Matrix<Paragraph>,
    scores: impl IntoIterator<Item = f32>,
    limit: usize,
    reason: &str,
    includes: impl Fn(f32) -> bool,
) -> Result<Vec<Hit>> {
    let mut best = HashMap::<i64, (f32, &Paragraph)>::new();
    for (row, score) in matrix.rows.iter().zip(scores) {
        if score.is_finite()
            && includes(score)
            && best.get(&row.document).is_none_or(|(prior, meta)| {
                score > *prior || score == *prior && row.chunk < meta.chunk
            })
        {
            best.insert(row.document, (score, row));
        }
    }
    let mut ranked: Vec<_> = best.into_values().collect();
    ranked.sort_unstable_by(|a, b| b.0.total_cmp(&a.0).then_with(|| a.1.path.cmp(&b.1.path)));
    let mut hits = Vec::new();
    {
        let (stamp, state_join) = document_stamp_sql(snapshot)?;
        let page = if crate::content::has_table(snapshot, "pdf_page")? {
            "(SELECT page FROM pdf_page p WHERE p.document_id=c.document_id AND p.start_byte<=c.start_byte AND c.end_byte<=p.end_byte LIMIT 1)"
        } else {
            "NULL"
        };
        let sql = format!(
            "SELECT i.path,i.display,i.kind,i.availability,
               CAST(substr(CAST(d.body AS BLOB), c.start_byte+1, c.end_byte-c.start_byte) AS TEXT),
               {stamp} AS document_stamp,{page}
             FROM semantic_chunk c JOIN document d ON d.id=c.document_id JOIN item i ON i.id=d.id
             {state_join} WHERE c.id=?1 AND i.id=?2 AND i.path=?3 AND i.availability IN ('local','provider_metadata_only')"
        );
        let mut hit = snapshot.prepare_cached(&sql)?;
        for (score, meta) in ranked {
            if hits.len() == limit {
                break;
            }
            if let Some(record) = hit
                .query_row(params![meta.chunk, meta.document, &*meta.path], |r| {
                    let mut record = row_hit(r, reason)?;
                    record.snippet = r.get(4)?;
                    record.document_stamp = read_document_stamp(r)?;
                    if record.document_stamp.is_some() {
                        record.pdf_page = r.get(6)?;
                    }
                    record.score = Some(score.into());
                    Ok(record)
                })
                .optional()?
            {
                hits.push(record);
            }
        }
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
    sample_ranges(ranges)
}

fn sample_ranges(ranges: Vec<Range<usize>>) -> Vec<Range<usize>> {
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
    #[test]
    fn gemma_eligibility_uses_current_model_visible_stamp_and_vector_shape() {
        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch("CREATE TABLE item(id INTEGER PRIMARY KEY,availability TEXT);
            CREATE TABLE document(id INTEGER PRIMARY KEY,body TEXT);
            CREATE TABLE document_state(id INTEGER PRIMARY KEY,stamp TEXT);
            CREATE TABLE embedding(id INTEGER PRIMARY KEY,vector BLOB);
            CREATE TABLE info(key TEXT PRIMARY KEY,value TEXT);
            INSERT INTO info VALUES('scope','{\"roots\":[],\"allow\":[],\"deny\":[],\"documents\":true,\"pdf_helper\":null}');
            INSERT INTO item VALUES(1,'local'),(2,'unverified'),(3,'local'),(4,'local');
            INSERT INTO document VALUES(1,'stale model'),(2,'unverified'),(3,'unstamped'),(4,'visible');
            INSERT INTO document_state VALUES(1,'1:2:3:4:5:6:7'),(2,'1:2:3:4:5:6:7'),(4,'1:2:3:4:5:6:7');").unwrap();
        conn.execute_batch(SCHEMA).unwrap();
        conn.execute_batch(VERSIONED_SCHEMA).unwrap();
        conn.execute_batch(
            "INSERT INTO semantic_chunk(id,document_id,start_byte,end_byte)
            VALUES(1,1,0,1),(2,2,0,1),(3,3,0,1),(4,4,0,1);
            INSERT INTO semantic_vector VALUES('old-gemma',1,zeroblob(3072));",
        )
        .unwrap();
        conn.execute("INSERT INTO semantic_vector VALUES(?1,2,zeroblob(3072)),(?1,3,zeroblob(3072)),(?1,4,'wrong type')", [gemma::ID]).unwrap();
        assert!(!gemma_searchable(&conn).unwrap());
        assert!(!gemma_coverage(&conn).unwrap().searchable());
        conn.execute("DELETE FROM semantic_vector WHERE chunk_id=4", [])
            .unwrap();
        let mut vector = vec![0_u8; GEMMA_VECTOR_BYTES as usize];
        vector[..4].copy_from_slice(&1.0_f32.to_le_bytes());
        conn.execute(
            "INSERT INTO semantic_vector VALUES(?1,4,?2)",
            params![gemma::ID, vector],
        )
        .unwrap();
        let coverage = gemma_coverage(&conn).unwrap();
        assert_eq!(coverage.embedded_chunks, 1);
        assert!(coverage.searchable() && coverage.pending);
        assert!(gemma_searchable(&conn).unwrap());
        conn.execute("DELETE FROM document WHERE id=4", []).unwrap();
        assert!(!gemma_searchable(&conn).unwrap());
    }

    use super::*;
    use crate::diagnose::snapshot_tests::{start_benign_writes, stop_benign_writes};
    use std::fs;

    fn query_vector() -> Vec<f32> {
        let mut query = vec![0.0; gemma::DIMENSIONS];
        query[0] = 1.0;
        query
    }

    #[test]
    fn gemma_searches_mixed_rows_caches_the_snapshot_and_gates_a_noisy_corpus() {
        let root = fs::canonicalize(std::env::temp_dir())
            .unwrap()
            .join(format!("lumen-gemma-matrix-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        let docs = root.join("docs");
        fs::create_dir_all(&docs).unwrap();
        for i in 0..8 {
            fs::write(
                docs.join(format!("doc-{i}.txt")),
                format!("Body number {i}"),
            )
            .unwrap();
        }
        let database = root.join("index.sqlite");
        crate::scan(
            &database,
            &crate::Scope {
                roots: vec![docs],
                documents: true,
                ..Default::default()
            },
        )
        .unwrap();
        let mut writer = Connection::open(&database).unwrap();
        while prepare_next_document(&mut writer, true).unwrap() {}
        let store = |writer: &Connection, i: usize| {
            let mut vector = vec![0.0_f32; gemma::DIMENSIONS];
            vector[0] = if i == 0 { 0.9375 } else { 0.6875 };
            vector[1] = (1.0 - vector[0].powi(2)).sqrt();
            let bytes = if i.is_multiple_of(2) {
                pack(&vector)
            } else {
                vector
                    .iter()
                    .flat_map(|value| value.to_le_bytes())
                    .collect()
            };
            assert_eq!(writer.execute(
                "INSERT INTO semantic_vector SELECT ?1,c.id,?2 FROM semantic_chunk c JOIN item i ON i.id=c.document_id WHERE i.display=?3",
                params![gemma::ID, bytes, format!("doc-{i}.txt")],
            ).unwrap(), 1);
        };
        store(&writer, 0);
        store(&writer, 1);
        assert_eq!(gemma_coverage(&writer).unwrap().embedded_chunks, 2);
        let mut session = GemmaSearchSession {
            conn: crate::open_read(&database).unwrap(),
            worker: GemmaQuery::Fixture(Box::new(query_vector)),
            matrix: MatrixCache::default(),
        };
        let lookup = |session: &mut GemmaSearchSession| {
            session
                .search("document fixture", 20)
                .unwrap()
                .into_iter()
                .map(|hit| (hit.name, hit.snippet.unwrap(), hit.score.unwrap()))
                .collect::<Vec<_>>()
        };
        let first = lookup(&mut session);
        assert_eq!(
            first,
            [
                ("doc-0.txt".into(), "Body number 0".into(), 0.9375),
                ("doc-1.txt".into(), "Body number 1".into(), 0.6875)
            ]
        );
        session.conn.execute_batch("BEGIN").unwrap();
        read_snapshot(&session.conn, |snapshot| {
            session.matrix.get(snapshot, |_| {
                panic!("unchanged catalog reloaded the matrix")
            })?;
            Ok(())
        })
        .unwrap();
        std::thread::scope(|thread| {
            thread
                .spawn(|| {
                    let writer = Connection::open(&database).unwrap();
                    let tx = writer.unchecked_transaction().unwrap();
                    for i in 2..8 {
                        store(&tx, i);
                    }
                    tx.commit().unwrap();
                })
                .join()
                .unwrap()
        });
        // The held WAL read transaction remains coherent during a writer commit.
        assert_eq!(lookup(&mut session), first);
        session.conn.execute_batch("COMMIT").unwrap();
        assert_eq!(lookup(&mut session), first[..1]);

        start_benign_writes(&session.conn, &database);
        for _ in 0..8 {
            assert_eq!(lookup(&mut session), first[..1]);
        }
        assert!(stop_benign_writes(&session.conn) >= 8);

        for (update, expected, revoked) in [
            (
                "UPDATE info SET value=json_set(value,'$.deny',json_array((SELECT path FROM item WHERE display='doc-0.txt'))) WHERE key='scope'",
                7,
                "doc-0.txt",
            ),
            (
                "UPDATE item SET availability='unverified' WHERE display='doc-1.txt'",
                6,
                "doc-1.txt",
            ),
            (
                "UPDATE info SET value=json_set(value,'$.documents',json('false')) WHERE key='scope'",
                0,
                "doc-2.txt",
            ),
        ] {
            let database = database.clone();
            session.worker = GemmaQuery::Fixture(Box::new(move || {
                // The writer commits after search starts but before ranking
                // pins its snapshot. This must invalidate the warm matrix.
                Connection::open(&database)
                    .unwrap()
                    .execute_batch(update)
                    .unwrap();
                query_vector()
            }));
            let hits = lookup(&mut session);
            assert_eq!(hits.len(), expected);
            assert!(hits.iter().all(|(name, _, _)| name != revoked));
        }
        drop(session);
        drop(writer);
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn legacy_search_uses_saved_scope_without_ending_the_callers_transaction() {
        use std::os::unix::fs::PermissionsExt;

        let root = fs::canonicalize(std::env::temp_dir())
            .unwrap()
            .join(format!("lumen-legacy-snapshot-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        let docs = root.join("docs");
        fs::create_dir_all(&docs).unwrap();
        let denied = docs.join("deny.txt");
        fs::write(&denied, "Denied paragraph").unwrap();
        fs::write(docs.join("keep.txt"), "Allowed paragraph").unwrap();
        let database = root.join("index.sqlite");
        crate::scan(
            &database,
            &Scope {
                roots: vec![docs],
                documents: true,
                ..Scope::default()
            },
        )
        .unwrap();
        let executable = root.join("encoder");
        fs::write(
            &executable,
            "#!/bin/sh\nprintf '%s\\n' '[1,0,0,0,0,0,0,0]'\n",
        )
        .unwrap();
        fs::set_permissions(&executable, fs::Permissions::from_mode(0o700)).unwrap();
        let model = Model {
            executable,
            language: "en".into(),
        };
        let backend = ModelBackend::Helper(&model);
        assert_eq!(embed_with_backend(&database, backend, 20).unwrap(), 2);
        let reader = crate::open_read(&database).unwrap();
        let writer = Connection::open(&database).unwrap();
        let lookup = |conn: &Connection| {
            crate::search_with_backend(
                conn,
                "document fixture",
                crate::Mode::Semantic,
                20,
                Some(backend),
            )
            .unwrap()
            .into_iter()
            .map(|hit| hit.name)
            .collect::<Vec<_>>()
        };
        start_benign_writes(&reader, &database);
        for _ in 0..8 {
            assert_eq!(lookup(&reader), ["deny.txt", "keep.txt"]);
        }
        assert!(stop_benign_writes(&reader) >= 8);

        let tx = reader.unchecked_transaction().unwrap();
        assert_eq!(lookup(&tx), ["deny.txt", "keep.txt"]);
        writer
            .execute(
                "UPDATE info SET value=json_set(value,'$.deny',json_array(?1)) WHERE key='scope'",
                [denied.to_str().unwrap()],
            )
            .unwrap();
        let retained: i64 = writer.query_row("SELECT count(*) FROM semantic_chunk c JOIN item i ON i.id=c.document_id WHERE i.path=?1 AND c.vector IS NOT NULL", [denied.to_str().unwrap()], |row| row.get(0)).unwrap();
        assert_eq!(retained, 1);
        // An already pinned caller-owned transaction keeps its old view.
        assert_eq!(lookup(&tx), ["deny.txt", "keep.txt"]);
        assert!(!reader.is_autocommit());
        tx.commit().unwrap();
        assert_eq!(lookup(&reader), ["keep.txt"]);
        drop(reader);
        drop(writer);
        fs::remove_dir_all(root).unwrap();
    }

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
