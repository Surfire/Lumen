use crate::{
    Hit, Model, ModelBackend, PdfHelperPolicy, Scope, absolute,
    diagnose::read_snapshot,
    document_stamp_sql, gemma,
    index::{DocumentKind, in_explicit_content_root},
    local_openai::{LocalOpenAiConfig, LocalOpenAiWorker, canonical_model_prefix},
    model::{Role, Unencodable},
    open_write, read_document_stamp, row_hit, saved_index_scope,
    vector::{Matrix, MatrixCache, adaptive_floor, pack},
};
use anyhow::{Context, Result, bail, ensure};
use rusqlite::{Connection, OptionalExtension, TransactionBehavior, params};
use std::{
    collections::HashMap,
    ops::Range,
    path::{Path, PathBuf},
    sync::atomic::{AtomicBool, Ordering},
    time::{Duration, Instant},
};

const CHUNK_CHARS: usize = 480;
const EARLIEST_BREAK: usize = 300;
const MAX_DOCUMENT_CHUNKS: usize = 128;
const MIN_TEXT_VECTOR_BYTES: u64 = 64 * 1024 * 1024;
const MAX_TEXT_VECTOR_BYTES: u64 = 1024 * 1024 * 1024;
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

// Additive to the legacy helper slot. The versioned store allows upgrades
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
    local_openai_coverage(conn, gemma::ID, gemma::DIMENSIONS)
}

pub fn local_openai_coverage(
    conn: &Connection,
    model_id: &str,
    dims: usize,
) -> Result<GemmaCoverage> {
    let tx = conn
        .is_autocommit()
        .then(|| conn.unchecked_transaction())
        .transpose()?;
    let coverage = read_model_coverage(tx.as_deref().unwrap_or(conn), model_id, dims)?;
    if let Some(tx) = tx {
        tx.commit()?;
    }
    Ok(coverage)
}

fn read_model_coverage(conn: &Connection, model_id: &str, dims: usize) -> Result<GemmaCoverage> {
    let mut coverage = GemmaCoverage {
        documents_enabled: documents_enabled(conn)?,
        embedded_chunks: 0,
        skipped_chunks: 0,
        pending: false,
        limited: false,
        chunk_limit: vector_limit(dims as i64),
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
    (coverage.embedded_chunks, coverage.skipped_chunks) = conn
        .prepare_cached(&format!(
            "SELECT count(*) FILTER (WHERE {GEMMA_VECTOR}), count(*) FILTER (WHERE v.vector IS NULL) {GEMMA_LIVE}"
        ))?
        .query_row(params![model_id, vector_bytes(dims)], |row| {
            Ok((row.get(0)?, row.get(1)?))
        })?;
    coverage.pending = model_pending(conn, model_id)?;
    coverage.limited = coverage.pending
        && coverage.chunk_limit > 0
        && model_count(conn, model_id)? >= coverage.chunk_limit;
    Ok(coverage)
}

fn parse_prefixed_model_dims(model_id: &str, prefix: &str) -> Option<usize> {
    let suffix = model_id.strip_prefix(prefix)?;
    let dims: usize = suffix.parse().ok()?;
    (8..=4096).contains(&dims).then_some(dims)
}

const LOCAL_OPENAI_STATUS_PROBE_TIMEOUT: Duration = Duration::from_millis(1500);

pub(crate) fn resolve_stored_local_openai_model(
    conn: &Connection,
    model_name: &str,
) -> Result<Option<(String, usize)>> {
    if crate::local_openai::sanitize_model_name(model_name).is_empty() {
        return Ok(None);
    }
    let prefix = canonical_model_prefix(model_name);
    let pending: Option<String> = conn
        .prepare_cached("SELECT value FROM info WHERE key='gemma_pending_model'")?
        .query_row([], |row| row.get(0))
        .optional()?;
    if let Some(model_id) = pending
        && let Some(dims) = parse_prefixed_model_dims(&model_id, &prefix)
    {
        return Ok(Some((model_id, dims)));
    }
    if !has_gemma_store(conn)? {
        return Ok(None);
    }
    // prefix always ends with '@' (0x40); upper bound swaps '@' -> 'A' (0x41)
    // for an exact B-tree range lookup on PRIMARY KEY(model, ...).
    let mut upper = prefix.clone();
    upper.pop();
    upper.push('A');
    let from_counts: Option<String> = conn
        .prepare_cached(
            "SELECT model FROM semantic_vector_count
             WHERE model >= ?1 AND model < ?2
             ORDER BY vectors DESC, model ASC LIMIT 1",
        )?
        .query_row(params![&prefix, &upper], |row| row.get(0))
        .optional()?;
    if let Some(model_id) = from_counts
        && let Some(dims) = parse_prefixed_model_dims(&model_id, &prefix)
    {
        return Ok(Some((model_id, dims)));
    }
    let from_vectors: Option<String> = conn
        .prepare_cached(
            "SELECT model FROM semantic_vector
             WHERE model >= ?1 AND model < ?2
             LIMIT 1",
        )?
        .query_row(params![&prefix, &upper], |row| row.get(0))
        .optional()?;
    if let Some(model_id) = from_vectors
        && let Some(dims) = parse_prefixed_model_dims(&model_id, &prefix)
    {
        return Ok(Some((model_id, dims)));
    }
    Ok(None)
}

pub(crate) fn resolve_local_openai_target(
    conn: &Connection,
    config: &LocalOpenAiConfig,
) -> Result<Option<(String, usize)>> {
    let model = config.model.trim();
    if model.is_empty() {
        return Ok(None);
    }
    if let Ok(worker) = LocalOpenAiWorker::new(config)
        && let Ok(live) = worker.probe_with_timeout(LOCAL_OPENAI_STATUS_PROBE_TIMEOUT)
    {
        return Ok(Some(live));
    }
    resolve_stored_local_openai_model(conn, model)
}

pub(crate) fn local_openai_status_coverage(
    conn: &Connection,
    config: &LocalOpenAiConfig,
) -> Result<(Option<String>, Option<usize>, GemmaCoverage)> {
    let target = resolve_local_openai_target(conn, config)?;
    if let Some((model_id, dims)) = target {
        let coverage = local_openai_coverage(conn, &model_id, dims)?;
        return Ok((Some(model_id), Some(dims), coverage));
    }
    let docs_enabled = documents_enabled(conn)?;
    let pending = if !docs_enabled {
        false
    } else if !has_gemma_store(conn)? {
        conn.query_row(
            "SELECT EXISTS(SELECT 1 FROM document JOIN item USING(id) WHERE availability IN ('local','provider_metadata_only'))",
            [],
            |row| row.get(0),
        )?
    } else {
        conn.query_row(
            "SELECT EXISTS(
                SELECT 1 FROM semantic_chunk c JOIN item i ON i.id=c.document_id
                JOIN document_state ds ON ds.id=c.document_id
                WHERE i.availability IN ('local','provider_metadata_only')
             ) OR EXISTS(
                SELECT 1 FROM semantic_document p JOIN item i ON i.id=p.document_id
                JOIN document_state ds ON ds.id=p.document_id
                WHERE p.prepared=0 AND i.availability IN ('local','provider_metadata_only')
             )",
            [],
            |row| row.get(0),
        )?
    };
    Ok((
        None,
        None,
        GemmaCoverage {
            documents_enabled: docs_enabled,
            embedded_chunks: 0,
            skipped_chunks: 0,
            pending,
            limited: false,
            chunk_limit: 0,
        },
    ))
}

fn has_gemma_store(conn: &Connection) -> Result<bool> {
    Ok(conn
        .prepare_cached(
            "SELECT count(*)=2 FROM sqlite_schema
         WHERE type='table' AND name IN ('semantic_vector','semantic_chunk')",
        )?
        .query_row([], |row| row.get(0))?)
}

fn model_searchable(conn: &Connection, model_id: &str, dims: usize) -> Result<bool> {
    read_snapshot(conn, |snapshot| {
        read_model_searchable(snapshot, model_id, dims)
    })
}

fn gemma_searchable(conn: &Connection) -> Result<bool> {
    model_searchable(conn, gemma::ID, gemma::DIMENSIONS)
}

fn read_model_searchable(conn: &Connection, model_id: &str, dims: usize) -> Result<bool> {
    Ok(documents_enabled(conn)?
        && has_gemma_store(conn)?
        && conn
            .prepare_cached(&format!(
                "SELECT EXISTS(SELECT 1 {GEMMA_LIVE} AND {GEMMA_VECTOR})"
            ))?
            .query_row(params![model_id, vector_bytes(dims)], |row| {
                row.get::<_, bool>(0)
            })?)
}

fn read_gemma_searchable(conn: &Connection) -> Result<bool> {
    read_model_searchable(conn, gemma::ID, gemma::DIMENSIONS)
}

fn vector_bytes(dims: usize) -> i64 {
    (dims * size_of::<f32>()) as i64
}

#[cfg(test)]
const GEMMA_VECTOR_BYTES: i64 = (gemma::DIMENSIONS * size_of::<f32>()) as i64;

const GEMMA_LIVE: &str = "FROM semantic_vector v JOIN semantic_chunk c ON c.id=v.chunk_id
    JOIN item i ON i.id=c.document_id JOIN document_state ds ON ds.id=c.document_id
    WHERE v.model=?1 AND i.availability IN ('local','provider_metadata_only')";
const GEMMA_VECTOR: &str = "typeof(v.vector)='blob' AND length(v.vector) IN (?2/2,?2)";
const GEMMA_MIN_COSINE: f32 = f32::MIN_POSITIVE;
const GEMMA_CORPUS_MIN_COSINE: f32 = 0.78;
const GEMMA_Z_THRESHOLD: f64 = 2.2;
const LOCAL_OPENAI_CORPUS_MIN_COSINE: f32 = 0.25;
const LOCAL_OPENAI_Z_THRESHOLD: f64 = 1.5;
const GEMMA_MIN_CHUNK_BYTES: usize = 24;

fn scope_state(conn: &Connection) -> Result<(Option<String>, bool)> {
    let saved: Option<String> = conn
        .query_row("SELECT value FROM info WHERE key='scope'", [], |row| {
            row.get(0)
        })
        .optional()?;
    let enabled = saved
        .as_deref()
        .map(serde_json::from_str::<crate::Scope>)
        .transpose()?
        .is_some_and(|scope| scope.documents);
    Ok((saved, enabled))
}

fn documents_enabled(conn: &Connection) -> Result<bool> {
    Ok(scope_state(conn)?.1)
}

const GEMMA_QUEUE: &str = "FROM semantic_chunk c JOIN item i ON i.id=c.document_id
    JOIN document_state ds ON ds.id=c.document_id WHERE i.availability IN ('local','provider_metadata_only') AND NOT EXISTS
       (SELECT 1 FROM semantic_vector v INDEXED BY semantic_vector_chunk WHERE v.model=?1 AND v.chunk_id=c.id)";

const GEMMA_QUEUE_FAST: &str = "FROM gemma_pending_chunk CROSS JOIN semantic_chunk c ON c.id=gemma_pending_chunk.chunk_id CROSS JOIN item i ON i.id=c.document_id CROSS JOIN document_state ds ON ds.id=c.document_id WHERE i.availability IN ('local','provider_metadata_only')";

fn has_model_pending_queue(conn: &Connection, model_id: &str) -> Result<bool> {
    let tables: bool = conn
        .prepare_cached(
            "SELECT count(*)=2 FROM sqlite_schema
             WHERE type='table' AND name IN ('gemma_pending_chunk','semantic_vector')",
        )?
        .query_row([], |row| row.get(0))?;
    if !tables {
        return Ok(false);
    }
    let model: Option<String> = conn
        .prepare_cached("SELECT value FROM info WHERE key='gemma_pending_model'")?
        .query_row([], |row| row.get(0))
        .optional()?;
    Ok(model.as_deref() == Some(model_id))
}

#[cfg(test)]
fn has_gemma_pending_queue(conn: &Connection) -> Result<bool> {
    has_model_pending_queue(conn, gemma::ID)
}

/// Preserve an already-active `openai-local:` or built-in Gemma pending queue on
/// generic writer opens (`watch`/`content`), initializing Gemma when absent or stale.
pub(crate) fn ensure_active_pending_queue(conn: &Connection) -> Result<()> {
    if !has_gemma_store(conn)? {
        return Ok(());
    }
    let tables: bool = conn
        .prepare_cached(
            "SELECT count(*)=2 FROM sqlite_schema
             WHERE type='table' AND name IN ('gemma_pending_chunk','semantic_vector')",
        )?
        .query_row([], |row| row.get(0))?;
    if tables {
        let model: Option<String> = conn
            .prepare_cached("SELECT value FROM info WHERE key='gemma_pending_model'")?
            .query_row([], |row| row.get(0))
            .optional()?;
        if model
            .as_deref()
            .is_some_and(|m| m == gemma::ID || m.starts_with("openai-local:"))
        {
            return Ok(());
        }
    }
    ensure_model_queue(conn, gemma::ID)
}

pub(crate) fn ensure_model_queue(conn: &Connection, model_id: &str) -> Result<()> {
    if has_model_pending_queue(conn, model_id)? || !has_gemma_store(conn)? {
        return Ok(());
    }
    let model_sql = model_id.replace('\'', "''");
    let ddl = format!(
        "CREATE TABLE IF NOT EXISTS gemma_pending_chunk(chunk_id INTEGER PRIMARY KEY);
         DROP TRIGGER IF EXISTS gemma_pending_chunk_inserted;
         CREATE TRIGGER gemma_pending_chunk_inserted AFTER INSERT ON semantic_chunk
         BEGIN
             INSERT OR IGNORE INTO gemma_pending_chunk(chunk_id)
             SELECT new.id WHERE NOT EXISTS(
                 SELECT 1 FROM semantic_vector WHERE model='{model_sql}' AND chunk_id=new.id
             );
         END;
         DROP TRIGGER IF EXISTS gemma_pending_chunk_deleted;
         CREATE TRIGGER gemma_pending_chunk_deleted AFTER DELETE ON semantic_chunk
         BEGIN
             DELETE FROM gemma_pending_chunk WHERE chunk_id=old.id;
         END;
         DROP TRIGGER IF EXISTS gemma_pending_vector_inserted;
         CREATE TRIGGER gemma_pending_vector_inserted AFTER INSERT ON semantic_vector
             WHEN new.model='{model_sql}'
         BEGIN
             DELETE FROM gemma_pending_chunk WHERE chunk_id=new.chunk_id;
         END;
         DROP TRIGGER IF EXISTS gemma_pending_vector_deleted;
         CREATE TRIGGER gemma_pending_vector_deleted AFTER DELETE ON semantic_vector
             WHEN old.model='{model_sql}'
         BEGIN
             INSERT OR IGNORE INTO gemma_pending_chunk(chunk_id)
             SELECT old.chunk_id WHERE EXISTS(
                 SELECT 1 FROM semantic_chunk WHERE id=old.chunk_id
             );
         END;"
    );
    let tx = conn
        .is_autocommit()
        .then(|| conn.unchecked_transaction())
        .transpose()?;
    let db = tx.as_deref().unwrap_or(conn);
    db.execute_batch(&ddl)?;
    db.execute("DELETE FROM gemma_pending_chunk", [])?;
    db.execute(
        "INSERT OR IGNORE INTO gemma_pending_chunk(chunk_id)
         SELECT c.id FROM semantic_chunk c
         WHERE NOT EXISTS (
             SELECT 1 FROM semantic_vector v INDEXED BY semantic_vector_chunk
             WHERE v.model=?1 AND v.chunk_id=c.id
         )",
        [model_id],
    )?;
    db.execute(
        "INSERT OR REPLACE INTO info(key,value) VALUES('gemma_pending_model',?1)",
        [model_id],
    )?;
    if let Some(tx) = tx {
        tx.commit()?;
    }
    Ok(())
}

pub(crate) fn ensure_gemma_queue(conn: &Connection) -> Result<()> {
    ensure_model_queue(conn, gemma::ID)
}

fn gemma_queue_fetch_sql(fast: bool) -> String {
    if fast {
        format!(
            "WITH next AS (SELECT c.id,c.document_id,c.start_byte,c.end_byte,i.mtime {GEMMA_QUEUE_FAST} AND gemma_pending_chunk.chunk_id>?1 ORDER BY i.mtime DESC,c.id LIMIT ?2)
             SELECT n.id, CAST(substr(CAST(d.body AS BLOB),n.start_byte+1,n.end_byte-n.start_byte) AS TEXT)
             FROM next n JOIN document d ON d.id=n.document_id ORDER BY n.mtime DESC,n.id"
        )
    } else {
        format!(
            "WITH next AS (SELECT c.id,c.document_id,c.start_byte,c.end_byte,i.mtime {GEMMA_QUEUE} AND c.id>?2 ORDER BY i.mtime DESC,c.id LIMIT ?3)
             SELECT n.id, CAST(substr(CAST(d.body AS BLOB),n.start_byte+1,n.end_byte-n.start_byte) AS TEXT)
             FROM next n JOIN document d ON d.id=n.document_id ORDER BY n.mtime DESC,n.id"
        )
    }
}

fn model_pending(conn: &Connection, model_id: &str) -> Result<bool> {
    if has_model_pending_queue(conn, model_id)? {
        return Ok(conn
            .prepare_cached(&format!(
                "SELECT EXISTS(SELECT 1 {GEMMA_QUEUE_FAST}) OR EXISTS(
                SELECT 1 FROM semantic_document p JOIN item i ON i.id=p.document_id
                JOIN document_state ds ON ds.id=p.document_id
                WHERE p.prepared=0 AND i.availability IN ('local','provider_metadata_only'))"
            ))?
            .query_row([], |row| row.get(0))?);
    }
    Ok(conn
        .prepare_cached(&format!(
            "SELECT EXISTS(SELECT 1 {GEMMA_QUEUE}) OR EXISTS(
            SELECT 1 FROM semantic_document p JOIN item i ON i.id=p.document_id
            JOIN document_state ds ON ds.id=p.document_id
            WHERE p.prepared=0 AND i.availability IN ('local','provider_metadata_only'))"
        ))?
        .query_row([model_id], |row| row.get(0))?)
}

#[cfg(test)]
fn gemma_pending(conn: &Connection) -> Result<bool> {
    model_pending(conn, gemma::ID)
}

fn model_count(conn: &Connection, model_id: &str) -> Result<i64> {
    Ok(conn
        .prepare_cached(
            "SELECT coalesce((SELECT vectors FROM semantic_vector_count WHERE model=?1),0)",
        )?
        .query_row([model_id], |row| row.get(0))?)
}

pub(super) fn diagnose_model(
    conn: &Connection,
    document: i64,
    model_id: &str,
    dims: usize,
) -> Result<crate::diagnose::Reason> {
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
        .query_row(params![model_id, vector_bytes(dims), document], |r| {
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
    let limit = vector_limit(dims as i64);
    if limit > 0 && model_count(conn, model_id)? >= limit {
        return Ok(Reason::GemmaLimited);
    }
    Ok(Reason::PendingGemma)
}

pub(super) fn diagnose_gemma(conn: &Connection, document: i64) -> Result<crate::diagnose::Reason> {
    diagnose_model(conn, document, gemma::ID, gemma::DIMENSIONS)
}

fn gemma_limit() -> i64 {
    vector_limit(gemma::DIMENSIONS as i64)
}

trait PassageEncoder {
    fn encode_passage(&mut self, text: &str) -> Result<Vec<f32>>;

    /// Passages handed to one `encode_passages` call between stop checks.
    fn batch_size(&self) -> usize {
        1
    }

    /// `None` marks an unencodable passage; `Err` is a hard runtime failure.
    fn encode_passages(&mut self, texts: &[&str]) -> Result<Vec<Option<Vec<f32>>>> {
        texts
            .iter()
            .map(|text| match self.encode_passage(text) {
                Ok(vector) => Ok(Some(vector)),
                Err(error) if error.is::<Unencodable>() => Ok(None),
                Err(error) => Err(error),
            })
            .collect()
    }
}

impl PassageEncoder for gemma::GemmaWorker {
    fn encode_passage(&mut self, text: &str) -> Result<Vec<f32>> {
        self.encode(Role::Passage, text)
    }

    fn batch_size(&self) -> usize {
        gemma::PASSAGE_BATCH
    }

    fn encode_passages(&mut self, texts: &[&str]) -> Result<Vec<Option<Vec<f32>>>> {
        gemma::GemmaWorker::encode_passages(self, texts)
    }
}

impl PassageEncoder for LocalOpenAiWorker {
    fn encode_passage(&mut self, text: &str) -> Result<Vec<f32>> {
        LocalOpenAiWorker::encode_passage(self, text)
    }

    fn batch_size(&self) -> usize {
        crate::local_openai::PASSAGE_BATCH
    }

    fn encode_passages(&mut self, texts: &[&str]) -> Result<Vec<Option<Vec<f32>>>> {
        LocalOpenAiWorker::encode_passages(self, texts)
    }
}

fn embed_model_batch(
    conn: &mut Connection,
    model_id: &str,
    dims: usize,
    encoder: &mut impl PassageEncoder,
    max: usize,
    initial_scope: Option<&str>,
    stop: Option<&AtomicBool>,
) -> Result<(EmbedBatch, bool)> {
    let (scope_now, enabled) = scope_state(conn)?;
    if !enabled || initial_scope.is_some_and(|expected| scope_now.as_deref() != Some(expected)) {
        return Ok((EmbedBatch::default(), true));
    }
    let limit = vector_limit(dims as i64);
    if model_count(conn, model_id)? >= limit || !model_pending(conn, model_id)? {
        return Ok((EmbedBatch::default(), false));
    }
    let max = max.clamp(1, MAX_BATCH);
    let mut items = Vec::with_capacity(max);
    let mut prepared = 0;
    let mut after = 0_i64;
    let extra_budget = max.max(32);
    let fast_queue = has_model_pending_queue(conn, model_id)?;
    let fetch_sql = gemma_queue_fetch_sql(fast_queue);
    while items.len() < max {
        if stop.is_some_and(|flag| flag.load(Ordering::Acquire)) {
            return Ok((EmbedBatch::default(), true));
        }
        let (scope_now, enabled) = scope_state(conn)?;
        if !enabled || initial_scope.is_some_and(|expected| scope_now.as_deref() != Some(expected))
        {
            return Ok((EmbedBatch::default(), true));
        }
        let remaining = (max - items.len()) as i64;
        let mut stmt = conn.prepare_cached(&fetch_sql)?;
        let map_row = |r: &rusqlite::Row<'_>| Ok((r.get::<_, i64>(0)?, r.get::<_, String>(1)?));
        let rows = if fast_queue {
            stmt.query_map(params![after, remaining], map_row)?
        } else {
            stmt.query_map(params![model_id, after, remaining], map_row)?
        };
        // A short fetch drains the queue, so later chunks come from newly
        // prepared documents whose AUTOINCREMENT ids exceed every fetched id.
        let mut fetched = 0;
        for row in rows {
            let (id, text) = row?;
            after = after.max(id);
            items.push((id, text));
            fetched += 1;
        }
        drop(stmt);
        if fetched == 0 {
            if prepared >= extra_budget || !prepare_next_document(conn, true)? {
                break;
            }
            prepared += 1;
        }
    }
    if items.is_empty() {
        let (scope_now, enabled) = scope_state(conn)?;
        let scope_mismatch =
            initial_scope.is_some_and(|expected| scope_now.as_deref() != Some(expected));
        let has_more = enabled
            && !scope_mismatch
            && model_count(conn, model_id)? < limit
            && model_pending(conn, model_id)?;
        return Ok((
            EmbedBatch {
                has_more,
                ..EmbedBatch::default()
            },
            !enabled || scope_mismatch,
        ));
    }

    let remaining_cap = (limit - model_count(conn, model_id)?).max(0) as usize;
    let mut encoded = Vec::with_capacity(items.len());
    let mut valid_encoded = 0usize;
    let mut stopped = false;
    for group in items.chunks(encoder.batch_size().max(1)) {
        if stop.is_some_and(|flag| flag.load(Ordering::Acquire)) {
            stopped = true;
            break;
        }
        if valid_encoded >= remaining_cap {
            break;
        }
        let texts: Vec<&str> = group.iter().map(|(_, text)| text.as_str()).collect();
        let vectors = encoder
            .encode_passages(&texts)
            .context("compute next semantic document chunk")?;
        ensure!(
            vectors.len() == group.len(),
            "embedding encoder returned a mismatched passage batch"
        );
        for ((id, _), vector) in group.iter().zip(vectors) {
            if let Some(ref values) = vector {
                ensure!(
                    values.len() == dims,
                    "embedding encoder returned {} dimensions, expected {dims}",
                    values.len()
                );
            }
            valid_encoded += usize::from(vector.is_some());
            encoded.push((*id, vector.map(|vector| pack(&vector))));
        }
    }

    let mut report = EmbedBatch::default();
    let mut scope_changed = false;
    if !encoded.is_empty() {
        let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let (scope_now, enabled) = scope_state(&tx)?;
        if !enabled || initial_scope.is_some_and(|expected| scope_now.as_deref() != Some(expected))
        {
            scope_changed = true;
        } else {
            let mut count = model_count(&tx, model_id)?;
            let mut insert = tx.prepare_cached(
                "INSERT OR IGNORE INTO semantic_vector(model,chunk_id,vector)
                 SELECT ?1,c.id,?3 FROM semantic_chunk c JOIN item i ON i.id=c.document_id
                 JOIN document_state ds ON ds.id=c.document_id WHERE c.id=?2 AND i.availability IN ('local','provider_metadata_only')",
            )?;
            for (id, vector) in encoded {
                if vector.is_some() && count >= limit {
                    break;
                }
                let saved = insert.execute(params![model_id, id, vector])?;
                if vector.is_some() {
                    count += saved as i64;
                    report.new_embeddings += saved;
                } else {
                    report.skipped_chunks += saved;
                }
            }
            drop(insert);
            tx.commit()?;
        }
    }
    let (scope_now, enabled) = scope_state(conn)?;
    let scope_mismatch =
        initial_scope.is_some_and(|expected| scope_now.as_deref() != Some(expected));
    report.has_more = enabled
        && !scope_mismatch
        && model_count(conn, model_id)? < limit
        && model_pending(conn, model_id)?;
    let yielded = stopped || scope_changed || !enabled || scope_mismatch;
    Ok((report, yielded))
}

fn embed_gemma_batch(
    conn: &mut Connection,
    encoder: &mut impl PassageEncoder,
    max: usize,
    initial_scope: Option<&str>,
    stop: Option<&AtomicBool>,
) -> Result<(EmbedBatch, bool)> {
    embed_model_batch(
        conn,
        gemma::ID,
        gemma::DIMENSIONS,
        encoder,
        max,
        initial_scope,
        stop,
    )
}

fn embed_gemma(conn: &mut Connection, model: &crate::GemmaModel, max: usize) -> Result<EmbedBatch> {
    ensure!(
        documents_enabled(conn)?,
        "Gemma requires explicit document indexing scope"
    );
    ensure_gemma_queue(conn)?;
    if model_count(conn, gemma::ID)? >= gemma_limit() || !model_pending(conn, gemma::ID)? {
        return Ok(EmbedBatch::default());
    }
    let mut encoder = model.start()?;
    Ok(embed_gemma_batch(conn, &mut encoder, max, None, None)?.0)
}

fn stream_model_with<E: PassageEncoder>(
    conn: &mut Connection,
    model_id: &str,
    dims: usize,
    max: usize,
    stop: &AtomicBool,
    connect: impl FnOnce() -> Result<E>,
    mut emit: impl FnMut(&EmbedBatch) -> Result<()>,
) -> Result<()> {
    let (initial_scope, enabled) = scope_state(conn)?;
    ensure!(
        enabled,
        "semantic indexing requires explicit document indexing scope"
    );
    ensure_model_queue(conn, model_id)?;
    let limit = vector_limit(dims as i64);
    if model_count(conn, model_id)? >= limit || !model_pending(conn, model_id)? {
        emit(&EmbedBatch::default())?;
        return Ok(());
    }
    let mut encoder = connect()?;
    loop {
        if stop.load(Ordering::Acquire) {
            break;
        }
        let started = Instant::now();
        let (batch, yielded) = embed_model_batch(
            conn,
            model_id,
            dims,
            &mut encoder,
            max,
            initial_scope.as_deref(),
            Some(stop),
        )?;
        if yielded && batch.new_embeddings == 0 && batch.skipped_chunks == 0 {
            break;
        }
        let done =
            !batch.has_more || (batch.new_embeddings == 0 && batch.skipped_chunks == 0) || yielded;
        emit(&batch)?;
        if done {
            break;
        }
        crate::platform::pace_stream_batch(started.elapsed(), stop);
    }
    Ok(())
}

fn stream_gemma_with<E: PassageEncoder>(
    conn: &mut Connection,
    max: usize,
    stop: &AtomicBool,
    connect: impl FnOnce() -> Result<E>,
    emit: impl FnMut(&EmbedBatch) -> Result<()>,
) -> Result<()> {
    stream_model_with(conn, gemma::ID, gemma::DIMENSIONS, max, stop, connect, emit)
}

pub fn embed_local_openai(
    database: &Path,
    config: &LocalOpenAiConfig,
    max: usize,
) -> Result<usize> {
    Ok(embed_local_openai_batch(database, config, max)?.new_embeddings)
}

pub fn embed_local_openai_batch(
    database: &Path,
    config: &LocalOpenAiConfig,
    max: usize,
) -> Result<EmbedBatch> {
    let database = absolute(database)?;
    ensure!(
        crate::open_read(&database).and_then(|conn| documents_enabled(&conn))?,
        "local OpenAI embedding requires explicit document indexing scope"
    );
    let mut worker = LocalOpenAiWorker::new(config)?;
    let (model_id, dims) = worker.probe()?;
    let (mut conn, _lease) = open_write(&database, false)?;
    ensure_model_queue(&conn, &model_id)?;
    if model_count(&conn, &model_id)? >= vector_limit(dims as i64)
        || !model_pending(&conn, &model_id)?
    {
        return Ok(EmbedBatch::default());
    }
    Ok(embed_model_batch(&mut conn, &model_id, dims, &mut worker, max, None, None)?.0)
}

pub fn stream_local_openai(
    database: &Path,
    config: &LocalOpenAiConfig,
    max: usize,
    stop: &AtomicBool,
    emit: impl FnMut(&EmbedBatch) -> Result<()>,
) -> Result<()> {
    let database = absolute(database)?;
    ensure!(
        crate::open_read(&database).and_then(|conn| documents_enabled(&conn))?,
        "local OpenAI embedding requires explicit document indexing scope"
    );
    let worker = LocalOpenAiWorker::new(config)?;
    let (model_id, dims) = worker.probe()?;
    let (mut conn, _lease) = open_write(&database, false)?;
    let mut worker = Some(worker);
    stream_model_with(
        &mut conn,
        &model_id,
        dims,
        max,
        stop,
        || worker.take().context("local OpenAI worker already started"),
        emit,
    )
}

pub(super) enum LocalOpenAiImageBackend {
    None,
    Ready(gemma::GemmaWorker),
    LazyHome(Option<PathBuf>),
    #[cfg(test)]
    Fixture(Box<dyn FnMut() -> Vec<f32> + Send>),
}

pub(super) enum GemmaQuery {
    Worker(gemma::GemmaWorker),
    LocalOpenAi {
        worker: LocalOpenAiWorker,
        model_id: String,
        dims: usize,
        image_backend: LocalOpenAiImageBackend,
    },
    #[cfg(test)]
    Fixture(Box<dyn FnMut() -> Vec<f32> + Send>),
}

impl GemmaQuery {
    pub fn encode(&mut self, text: &str) -> Result<Vec<f32>> {
        match self {
            Self::Worker(worker) => worker.encode(Role::Query, text),
            Self::LocalOpenAi { worker, .. } => worker.encode_query(text),
            #[cfg(test)]
            Self::Fixture(encode) => Ok(encode()),
        }
    }
}

pub type SemanticSearchSession = GemmaSearchSession;

pub struct GemmaSearchSession {
    conn: Connection,
    worker: GemmaQuery,
    matrix: MatrixCache<Paragraph>,
    /// Present when the Gemma image projector is installed: stored image
    /// vectors are blended into unified semantic results for built-in Gemma,
    /// and queried independently via `search_images` for Local OpenAI sessions.
    images: Option<crate::image_search::ImageCache>,
}

/// At most this share of a semantic result list comes from image vectors.
const IMAGE_BLEND_DIVISOR: usize = 4;

/// Insert image hits among document hits by score, keeping the document
/// order intact. Reserve slots for cross-modal image hits (capped to at most
/// the image share) so higher-scoring text hits do not squeeze them out.
fn blend_image_hits(hits: &mut Vec<Hit>, images: Vec<Hit>, limit: usize) {
    let mut deduped = Vec::new();
    for image in images {
        if !hits.iter().any(|hit| hit.path == image.path)
            && !deduped.iter().any(|hit: &Hit| hit.path == image.path)
        {
            deduped.push(image);
        }
    }
    let existing_images = hits
        .iter()
        .filter(|hit| hit.matched_by == "image_embedding")
        .count();
    let max_images = if limit == 0 {
        0
    } else {
        (limit / IMAGE_BLEND_DIVISOR).max(1).min(limit)
    };
    let reserved = deduped
        .len()
        .min(max_images.saturating_sub(existing_images));
    hits.truncate(limit.saturating_sub(reserved));
    for image in deduped {
        let score = image.score.unwrap_or(f64::MIN);
        let at = hits
            .iter()
            .position(|hit| hit.score.unwrap_or(f64::MIN) < score)
            .unwrap_or(hits.len());
        hits.insert(at, image);
    }
    hits.truncate(limit);
}

impl GemmaSearchSession {
    pub fn open(database: &Path, model: &crate::GemmaModel) -> Result<Self> {
        let conn = crate::open_read(database)?;
        let has_projector = model.has_image_projector();
        let can_search = |conn: &Connection| -> Result<bool> {
            Ok(gemma_searchable(conn)?
                || (has_projector && crate::image_search::has_vectors(conn)?))
        };
        ensure!(
            can_search(&conn)?,
            "no current Gemma embeddings: run lumen embed --gemma or image-index first"
        );
        let mut worker = model.start()?;
        worker.probe()?;
        ensure!(
            can_search(&conn)?,
            "Gemma document or image coverage changed while starting the runtime"
        );
        Ok(Self {
            conn,
            worker: GemmaQuery::Worker(worker),
            matrix: MatrixCache::default(),
            images: has_projector.then(Default::default),
        })
    }

    pub fn open_local_openai(
        database: &Path,
        config: &LocalOpenAiConfig,
        image_gemma: Option<&crate::GemmaModel>,
    ) -> Result<Self> {
        let conn = crate::open_read(database)?;
        let worker = LocalOpenAiWorker::new(config)?;
        let (model_id, dims) = worker.probe()?;
        let has_text = model_searchable(&conn, &model_id, dims)?;
        let has_projector = image_gemma.is_some_and(crate::GemmaModel::has_image_projector);
        let has_images = has_projector && crate::image_search::has_vectors(&conn)?;
        ensure!(
            has_text || has_images,
            "no current local OpenAI embeddings: run lumen embed --openai-url ... --openai-model ... first"
        );
        let image_backend = if has_images {
            let model = image_gemma.expect("image_gemma present when has_images");
            let started = model.start().and_then(|mut w| {
                w.probe()?;
                Ok(w)
            });
            match started {
                Ok(w) => LocalOpenAiImageBackend::Ready(w),
                Err(_) if has_text => LocalOpenAiImageBackend::None,
                Err(err) => return Err(err),
            }
        } else {
            LocalOpenAiImageBackend::None
        };
        let images =
            (!matches!(image_backend, LocalOpenAiImageBackend::None)).then(Default::default);
        Ok(Self {
            conn,
            worker: GemmaQuery::LocalOpenAi {
                worker,
                model_id,
                dims,
                image_backend,
            },
            matrix: MatrixCache::default(),
            images,
        })
    }

    /// Open a Local OpenAI text session while deferring built-in Gemma startup
    /// until `search_images` is explicitly called, avoiding cold-start overhead
    /// on pure text queries.
    pub fn open_local_openai_with_gemma_home(
        database: &Path,
        config: &LocalOpenAiConfig,
        gemma_home: Option<&Path>,
    ) -> Result<Self> {
        let conn = crate::open_read(database)?;
        let worker = LocalOpenAiWorker::new(config)?;
        let (model_id, dims) = worker.probe()?;
        let has_text = model_searchable(&conn, &model_id, dims)?;
        let has_projector =
            crate::GemmaModel::installed(gemma_home).is_ok_and(|m| m.has_image_projector());
        let has_images = has_projector && crate::image_search::has_vectors(&conn)?;
        ensure!(
            has_text || has_images,
            "no current local OpenAI embeddings: run lumen embed --openai-url ... --openai-model ... first"
        );
        let image_backend = if has_projector {
            LocalOpenAiImageBackend::LazyHome(gemma_home.map(Path::to_path_buf))
        } else {
            LocalOpenAiImageBackend::None
        };
        Ok(Self {
            conn,
            worker: GemmaQuery::LocalOpenAi {
                worker,
                model_id,
                dims,
                image_backend,
            },
            matrix: MatrixCache::default(),
            images: has_projector.then(Default::default),
        })
    }

    pub fn search(&mut self, query: &str, limit: usize) -> Result<Vec<Hit>> {
        let query = query.trim();
        if query.is_empty() || query.len() > 512 || !crate::query_allows_semantic(query) {
            return Ok(Vec::new());
        }
        let limit = limit.clamp(1, 100);
        if let GemmaQuery::LocalOpenAi {
            worker,
            model_id,
            dims,
            ..
        } = &mut self.worker
        {
            // Local OpenAI text search is strictly decoupled from Gemma image vectors.
            let vector = match worker.encode_query(query) {
                Ok(vector) => vector,
                Err(error) if error.is::<Unencodable>() => return Ok(Vec::new()),
                Err(error) => return Err(error),
            };
            ensure!(
                vector.len() == *dims,
                "local OpenAI query vector dimensions ({}) differ from expected ({dims})",
                vector.len()
            );
            let mut hits = read_snapshot(&self.conn, |snapshot| {
                rank_model(snapshot, model_id, *dims, &vector, limit, &mut self.matrix)
            })?;
            hits.retain(|hit| !crate::external::is_external(Path::new(&hit.path)));
            return Ok(hits);
        }
        let Some(images) = &mut self.images else {
            let mut hits =
                search_gemma(&self.conn, query, limit, &mut self.worker, &mut self.matrix)?;
            hits.retain(|hit| !crate::external::is_external(Path::new(&hit.path)));
            return Ok(hits);
        };
        // One query vector ranks both paragraphs and images.
        let vector = match self.worker.encode(query) {
            Ok(vector) => vector,
            Err(error) if error.is::<Unencodable>() => return Ok(Vec::new()),
            Err(error) => return Err(error),
        };
        let mut hits = read_snapshot(&self.conn, |snapshot| {
            rank_gemma(snapshot, &vector, limit, &mut self.matrix)
        })?;
        let cap = (limit / IMAGE_BLEND_DIVISOR).max(1);
        let image_hits = crate::image_search::rank_with_query(&self.conn, images, &vector, cap)?;
        blend_image_hits(&mut hits, image_hits, limit);
        hits.retain(|hit| !crate::external::is_external(Path::new(&hit.path)));
        Ok(hits)
    }

    pub fn search_images(&mut self, query: &str, limit: usize) -> Result<Vec<Hit>> {
        let query = query.trim();
        if query.is_empty() || query.len() > 512 || !crate::query_allows_semantic(query) {
            return Ok(Vec::new());
        }
        let Some(images) = &mut self.images else {
            return Ok(Vec::new());
        };
        let vector = match &mut self.worker {
            GemmaQuery::LocalOpenAi { image_backend, .. } => {
                // Image search always uses built-in Gemma 2 + mmproj, never external OpenAI vectors.
                if let LocalOpenAiImageBackend::LazyHome(home) = image_backend {
                    let model = crate::GemmaModel::installed(home.as_deref())?;
                    if !model.has_image_projector() {
                        *image_backend = LocalOpenAiImageBackend::None;
                        return Ok(Vec::new());
                    }
                    let mut started = model.start()?;
                    started.probe()?;
                    *image_backend = LocalOpenAiImageBackend::Ready(started);
                }
                match image_backend {
                    LocalOpenAiImageBackend::None | LocalOpenAiImageBackend::LazyHome(_) => {
                        return Ok(Vec::new());
                    }
                    LocalOpenAiImageBackend::Ready(worker) => {
                        match worker.encode(Role::Query, query) {
                            Ok(vector) => vector,
                            Err(error) if error.is::<Unencodable>() => return Ok(Vec::new()),
                            Err(error) => return Err(error),
                        }
                    }
                    #[cfg(test)]
                    LocalOpenAiImageBackend::Fixture(encode) => encode(),
                }
            }
            worker => match worker.encode(query) {
                Ok(vector) => vector,
                Err(error) if error.is::<Unencodable>() => return Ok(Vec::new()),
                Err(error) => return Err(error),
            },
        };
        let mut hits =
            crate::image_search::rank_with_query(&self.conn, images, &vector, limit.clamp(1, 20))?;
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

pub(crate) fn vector_limit_for_memory(dimensions: i64, ram_bytes: u64) -> i64 {
    if dimensions <= 0 {
        return 0;
    }
    let budget = (ram_bytes / 40).clamp(MIN_TEXT_VECTOR_BYTES, MAX_TEXT_VECTOR_BYTES);
    let bytes_per_vec = (dimensions as u64).saturating_mul(2).max(16);
    (budget / bytes_per_vec) as i64
}

fn vector_limit(dimensions: i64) -> i64 {
    vector_limit_for_memory(dimensions, crate::platform::physical_memory_bytes())
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

impl EmbedBatch {
    pub fn stream(
        database: &Path,
        model: ModelBackend<'_>,
        max: usize,
        stop: &AtomicBool,
        mut emit: impl FnMut(&Self) -> Result<()>,
    ) -> Result<()> {
        let database = absolute(database)?;
        match model {
            ModelBackend::Gemma(model) => {
                ensure!(
                    crate::open_read(&database).and_then(|conn| documents_enabled(&conn))?,
                    "Gemma requires explicit document indexing scope"
                );
                let (mut conn, _lease) = open_write(&database, false)?;
                stream_gemma_with(&mut conn, max, stop, || model.start(), &mut emit)
            }
            ModelBackend::LocalOpenAi(config) => {
                stream_local_openai(&database, config, max, stop, emit)
            }
            other => {
                let (mut conn, _lease) = open_write(&database, false)?;
                let mut encoder = other.connect()?;
                let signature = encoder.signature().to_owned();
                let initial_scope = scope_state(&conn)?.0;
                let mut expected = State::read(&conn)?.model;
                loop {
                    if stop.load(Ordering::Acquire) || scope_state(&conn)?.0 != initial_scope {
                        break;
                    }
                    let batch = embed_encoder_batch(
                        &mut conn,
                        &mut encoder,
                        &signature,
                        &mut expected,
                        max,
                    )?;
                    let done = !batch.has_more
                        || (batch.new_embeddings == 0 && batch.skipped_chunks == 0)
                        || stop.load(Ordering::Acquire)
                        || scope_state(&conn)?.0 != initial_scope;
                    emit(&batch)?;
                    if done {
                        break;
                    }
                }
                Ok(())
            }
        }
    }
}

pub fn embed_batch(database: &Path, model: ModelBackend<'_>, max: usize) -> Result<EmbedBatch> {
    if let ModelBackend::LocalOpenAi(config) = model {
        return embed_local_openai_batch(database, config, max);
    }
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
    embed_encoder_batch(&mut conn, &mut encoder, &signature, &mut expected, max)
}

fn embed_encoder_batch(
    conn: &mut Connection,
    encoder: &mut crate::model::Encoder<'_>,
    signature: &str,
    expected: &mut Option<String>,
    max: usize,
) -> Result<EmbedBatch> {
    let mut report = EmbedBatch::default();
    let mut prepared = 0;
    let mut attempted = 0;
    let mut unencodable = 0;
    let max = max.clamp(1, MAX_BATCH);
    let extra_budget = max.max(32);
    while attempted < max && unencodable < extra_budget {
        let state = State::read(conn)?;
        state.check_model(signature, expected.as_deref())?;
        let reuse = state.model.as_deref() == Some(signature);
        if reuse && state.full() {
            break;
        }
        let Some((id, text)) = next_chunk(conn, reuse, signature)? else {
            if prepared >= extra_budget || !prepare_next_document(conn, false)? {
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
                report.skipped_chunks += save_skip(conn, id, signature, expected.as_deref())?;
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
        if save_vector(conn, id, &vector, signature, expected.as_deref())? {
            *expected = Some(signature.to_owned());
            report.new_embeddings += 1;
        }
    }
    let state = State::read(conn)?;
    state.check_model(signature, expected.as_deref())?;
    let reuse = state.model.as_deref() == Some(signature);
    if !(reuse && state.full()) {
        report.has_more = next_chunk(conn, reuse, signature)?.is_some()
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

const PREPARE_DOCUMENTS: i64 = 16;

/// Chunks the newest pending documents; one ordered scan prepares several.
fn prepare_next_document(conn: &mut Connection, require_stamp: bool) -> Result<bool> {
    let documents: Vec<i64> = conn
        .prepare_cached(
            "SELECT p.document_id FROM semantic_document p JOIN item i ON i.id=p.document_id
             WHERE p.prepared=0 AND i.availability IN ('local','provider_metadata_only')
             AND EXISTS(SELECT 1 FROM document d WHERE d.id=p.document_id)
             AND (NOT ?1 OR EXISTS(SELECT 1 FROM document_state ds WHERE ds.id=p.document_id))
             ORDER BY i.mtime DESC,p.document_id LIMIT ?2",
        )?
        .query_map(params![require_stamp, PREPARE_DOCUMENTS], |r| r.get(0))?
        .collect::<rusqlite::Result<_>>()?;
    if documents.is_empty() {
        return Ok(false);
    }
    let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
    for id in documents {
        let Some(body) = tx
            .prepare_cached("SELECT body FROM document WHERE id=?1")?
            .query_row([id], |r| r.get::<_, String>(0))
            .optional()?
        else {
            continue;
        };
        prepare_document(&tx, id, &body, require_stamp)?;
    }
    tx.commit()?;
    Ok(true)
}

fn prepare_document(tx: &Connection, id: i64, body: &str, require_stamp: bool) -> Result<()> {
    let new = tx
        .prepare_cached(
            "UPDATE semantic_document SET prepared=1 WHERE document_id=?1 AND prepared=0
         AND EXISTS(SELECT 1 FROM document d JOIN item i USING(id)
                    WHERE d.id=?1 AND d.body=?2 AND i.availability IN ('local','provider_metadata_only')
                    AND (NOT ?3 OR EXISTS(SELECT 1 FROM document_state ds WHERE ds.id=d.id)))",
        )?
        .execute(params![id, body, require_stamp])?;
    if new != 0 {
        let pages = crate::content::pages(tx, id)?;
        let ranges = if pages.is_empty() {
            chunk_ranges(body)
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
    Ok(())
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
    if let ModelBackend::LocalOpenAi(config) = model {
        let worker = LocalOpenAiWorker::new(config)?;
        let (model_id, dims) = worker.probe()?;
        ensure!(
            read_model_searchable(conn, &model_id, dims)?,
            "no current local OpenAI paragraph embeddings: run lumen embed --openai-url ... --openai-model ... first"
        );
        let vector = match worker.encode_query(query) {
            Ok(vector) => vector,
            Err(error) if error.is::<Unencodable>() => return Ok(Vec::new()),
            Err(error) => return Err(error),
        };
        ensure!(
            vector.len() == dims,
            "local OpenAI query vector dimensions ({}) differ from expected ({dims})",
            vector.len()
        );
        return read_snapshot(conn, |snapshot| {
            rank_model(
                snapshot,
                &model_id,
                dims,
                &vector,
                limit,
                &mut MatrixCache::default(),
            )
        });
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

const LEGACY: &str = "SELECT c.document_id, c.id, i.path, c.vector, c.end_byte - c.start_byte FROM semantic_chunk c
    JOIN item i ON i.id=c.document_id WHERE i.availability IN ('local','provider_metadata_only') AND c.vector IS NOT NULL";

struct Paragraph {
    document: i64,
    chunk: i64,
    path: Box<str>,
    bytes: usize,
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
        let bytes = row.get::<_, i64>(4)?.max(0) as usize;
        let meta = Paragraph {
            document: row.get(0)?,
            chunk: row.get(1)?,
            path: path.into(),
            bytes,
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
    rank_model(snapshot, gemma::ID, gemma::DIMENSIONS, query, limit, cache)
}

fn rank_model(
    snapshot: &Connection,
    model_id: &str,
    dims: usize,
    query: &[f32],
    limit: usize,
    cache: &mut MatrixCache<Paragraph>,
) -> Result<Vec<Hit>> {
    ensure!(
        query.len() == dims,
        "stored and query embedding dimensions differ ({} vs {dims})",
        query.len()
    );
    let matrix = cache.get_for_bucket(snapshot, "vec_generation", |snapshot| {
        let Some(scope) = saved_index_scope(snapshot)?.filter(|scope| scope.documents) else {
            return Ok(Matrix::new(dims));
        };
        if !has_gemma_store(snapshot)? {
            return Ok(Matrix::new(dims));
        }
        load_paragraphs(
            snapshot,
            dims,
            &format!("SELECT c.document_id,c.id,i.path,v.vector,c.end_byte-c.start_byte {GEMMA_LIVE} AND {GEMMA_VECTOR} AND i.kind='file'"),
            params![model_id, vector_bytes(dims)],
            |path| paragraph_path_allowed(&scope, path),
        )
    })?;
    let mut substantive_docs = std::collections::HashSet::new();
    for row in &matrix.rows {
        if row.bytes >= GEMMA_MIN_CHUNK_BYTES {
            substantive_docs.insert(row.document);
        }
    }
    let scores: Vec<f32> = matrix
        .rows
        .iter()
        .zip(matrix.scores(query))
        .map(|(row, score)| {
            if row.bytes < GEMMA_MIN_CHUNK_BYTES && substantive_docs.contains(&row.document) {
                f32::NAN
            } else {
                score
            }
        })
        .collect();
    let finite_count = scores.iter().filter(|s| s.is_finite()).count();
    let (corpus_min_cosine, z_threshold) = if model_id == gemma::ID {
        (GEMMA_CORPUS_MIN_COSINE, GEMMA_Z_THRESHOLD)
    } else {
        (LOCAL_OPENAI_CORPUS_MIN_COSINE, LOCAL_OPENAI_Z_THRESHOLD)
    };
    let min_cosine = if finite_count >= 8 {
        corpus_min_cosine
    } else {
        GEMMA_MIN_COSINE
    };
    let floor = adaptive_floor(&scores, min_cosine, z_threshold);
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
    fn image_hits_blend_by_score_without_reordering_documents() {
        let hit = |path: &str, matched_by: &str, score: f64| Hit {
            path: path.into(),
            name: path.into(),
            kind: "file".into(),
            availability: "local".into(),
            matched_by: matched_by.into(),
            snippet: None,
            document_stamp: None,
            pdf_page: None,
            score: Some(score),
        };
        let mut hits = vec![
            hit("/d/a.md", "semantic", 0.9),
            hit("/d/b.md", "semantic", 0.8),
            hit("/d/c.md", "semantic", 0.7),
        ];
        blend_image_hits(&mut hits, vec![hit("/p/x.png", "image_embedding", 0.85)], 4);
        let order: Vec<_> = hits.iter().map(|hit| hit.path.as_str()).collect();
        assert_eq!(order, ["/d/a.md", "/p/x.png", "/d/b.md", "/d/c.md"]);
        blend_image_hits(&mut hits, vec![hit("/p/y.png", "image_embedding", 0.1)], 4);
        assert_eq!(hits.len(), 4);
        assert!(hits.iter().all(|hit| hit.path != "/p/y.png"));
    }

    #[test]
    fn blend_image_hits_preserves_cross_modal_images_when_higher_scoring_text_fills_limit() {
        let hit = |path: &str, matched_by: &str, score: f64| Hit {
            path: path.into(),
            name: path.into(),
            kind: "file".into(),
            availability: "local".into(),
            matched_by: matched_by.into(),
            snippet: None,
            document_stamp: None,
            pdf_page: None,
            score: Some(score),
        };
        let mut hits = vec![
            hit("/d/1.md", "semantic", 0.85),
            hit("/d/2.md", "semantic", 0.85),
            hit("/d/3.md", "semantic", 0.85),
            hit("/d/4.md", "semantic", 0.85),
        ];
        blend_image_hits(
            &mut hits,
            vec![hit("/p/photo.png", "image_embedding", 0.70)],
            4,
        );
        let order: Vec<_> = hits.iter().map(|hit| hit.path.as_str()).collect();
        assert_eq!(order, ["/d/1.md", "/d/2.md", "/d/3.md", "/p/photo.png"]);

        let mut higher = vec![
            hit("/d/1.md", "semantic", 0.85),
            hit("/d/2.md", "semantic", 0.85),
            hit("/d/3.md", "semantic", 0.85),
            hit("/d/4.md", "semantic", 0.85),
        ];
        blend_image_hits(
            &mut higher,
            vec![hit("/p/top.png", "image_embedding", 0.95)],
            4,
        );
        let order: Vec<_> = higher.iter().map(|hit| hit.path.as_str()).collect();
        assert_eq!(order, ["/p/top.png", "/d/1.md", "/d/2.md", "/d/3.md"]);
    }

    #[test]
    fn gemma_session_search_images_ranks_only_images_and_respects_projector_gate() {
        let root = fs::canonicalize(std::env::temp_dir())
            .unwrap()
            .join(format!("lumen-gemma-search-images-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        let folder = root.join("media");
        fs::create_dir_all(&folder).unwrap();
        let photo = folder.join("sunset.png");
        fs::write(&photo, "image fixture").unwrap();
        let database = root.join("index.sqlite");
        crate::scan(
            &database,
            &Scope {
                roots: vec![folder.clone()],
                ..Scope::default()
            },
        )
        .unwrap();
        crate::image_scope(&database, Some(&folder)).unwrap();
        let writer = Connection::open(&database).unwrap();
        let query_vector = || {
            let mut v = vec![0.0_f32; gemma::DIMENSIONS];
            v[0] = 1.0;
            v
        };
        let stamp = crate::diagnose::local_stamp(&photo, false).unwrap();
        writer
            .execute(
                "INSERT INTO image_embedding SELECT id,?1,?2,?3 FROM item WHERE path=?4",
                params![
                    crate::IMAGE_MODEL_ID,
                    stamp,
                    pack(&query_vector()),
                    photo.to_str().unwrap()
                ],
            )
            .unwrap();
        drop(writer);

        let mut without_projector = GemmaSearchSession {
            conn: crate::open_read(&database).unwrap(),
            worker: GemmaQuery::Fixture(Box::new(query_vector)),
            matrix: MatrixCache::default(),
            images: None,
        };
        assert!(
            without_projector
                .search_images("sunset beach", 10)
                .unwrap()
                .is_empty()
        );

        let mut with_projector = GemmaSearchSession {
            conn: crate::open_read(&database).unwrap(),
            worker: GemmaQuery::Fixture(Box::new(query_vector)),
            matrix: MatrixCache::default(),
            images: Some(Default::default()),
        };
        let hits = with_projector.search_images("sunset beach", 10).unwrap();
        assert_eq!(hits.len(), 1);
        assert_eq!(hits[0].path, photo.to_str().unwrap());
        assert_eq!(hits[0].matched_by, "image_embedding");
        assert!(with_projector.search_images("   ", 10).unwrap().is_empty());

        drop(without_projector);
        drop(with_projector);
        fs::remove_dir_all(root).unwrap();
    }

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
            images: None,
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
            session
                .matrix
                .get_for_bucket(snapshot, "vec_generation", |_| {
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

        let vec_before = crate::bucket_generation(&session.conn, "vec_generation").unwrap();
        start_benign_writes(&session.conn, &database);
        for _ in 0..8 {
            assert_eq!(lookup(&mut session), first[..1]);
        }
        assert!(stop_benign_writes(&session.conn) >= 8);
        assert_eq!(
            crate::bucket_generation(&session.conn, "vec_generation").unwrap(),
            vec_before
        );
        read_snapshot(&session.conn, |snapshot| {
            session
                .matrix
                .get_for_bucket(snapshot, "vec_generation", |_| {
                    panic!("unrelated item write reloaded semantic matrix")
                })?;
            Ok(())
        })
        .unwrap();

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
            "#!/bin/sh\ncat >/dev/null\nprintf '%s\\n' '[1,0,0,0,0,0,0,0]'\n",
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
        const GIB: u64 = 1024 * 1024 * 1024;
        assert_eq!(vector_limit_for_memory(0, 16 * GIB), 0);
        assert_eq!(vector_limit_for_memory(-768, 16 * GIB), 0);
        assert_eq!(
            vector_limit_for_memory(512, 2 * GIB),
            (MIN_TEXT_VECTOR_BYTES / (512 * 2)) as i64
        );
        assert_eq!(
            vector_limit_for_memory(512, 8 * GIB),
            ((8 * GIB / 40) / (512 * 2)) as i64
        );
        assert_eq!(
            vector_limit_for_memory(768, 8 * GIB),
            ((8 * GIB / 40) / (768 * 2)) as i64
        );
        assert_eq!(
            vector_limit_for_memory(768, 16 * GIB),
            ((16 * GIB / 40) / (768 * 2)) as i64
        );
        assert_eq!(
            vector_limit_for_memory(4096, 16 * GIB),
            ((16 * GIB / 40) / (4096 * 2)) as i64
        );
        assert_eq!(
            vector_limit_for_memory(768, 64 * GIB),
            (MAX_TEXT_VECTOR_BYTES / (768 * 2)) as i64
        );
        assert_eq!(
            vector_limit_for_memory(4096, 128 * GIB),
            (MAX_TEXT_VECTOR_BYTES / (4096 * 2)) as i64
        );
        assert_eq!(
            vector_limit_for_memory(768, 64 * GIB),
            vector_limit_for_memory(768, 128 * GIB)
        );
        assert!(vector_limit(768) >= (MIN_TEXT_VECTOR_BYTES / (768 * 2)) as i64);
    }

    #[test]
    fn gemma_stream_connects_once_commits_batches_atomically_and_yields_on_stop_or_scope_change() {
        let root = fs::canonicalize(std::env::temp_dir())
            .unwrap()
            .join(format!("lumen-gemma-stream-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        let docs = root.join("docs");
        fs::create_dir_all(&docs).unwrap();
        for i in 0..5 {
            fs::write(docs.join(format!("doc-{i}.txt")), format!("Paragraph {i}")).unwrap();
        }
        let database = root.join("index.sqlite");
        crate::scan(
            &database,
            &Scope {
                roots: vec![docs.clone()],
                documents: true,
                ..Scope::default()
            },
        )
        .unwrap();

        type EncodeCallback = Box<dyn FnMut(usize, &str) -> Result<Vec<f32>>>;
        struct MockEncoder {
            calls: usize,
            on_encode: EncodeCallback,
        }
        impl PassageEncoder for MockEncoder {
            fn encode_passage(&mut self, text: &str) -> Result<Vec<f32>> {
                self.calls += 1;
                (self.on_encode)(self.calls, text)
            }
        }

        let (mut conn, _lease) = open_write(&database, false).unwrap();
        let mut connect_count = 0usize;
        let stop = AtomicBool::new(false);
        let mut batches = Vec::new();
        stream_gemma_with(
            &mut conn,
            2,
            &stop,
            || {
                connect_count += 1;
                Ok(MockEncoder {
                    calls: 0,
                    on_encode: Box::new(|call, _| {
                        if call == 2 {
                            return Err(Unencodable.into());
                        }
                        Ok(query_vector())
                    }),
                })
            },
            |batch| {
                batches.push((batch.new_embeddings, batch.skipped_chunks, batch.has_more));
                Ok(())
            },
        )
        .unwrap();
        assert_eq!(connect_count, 1);
        assert_eq!(batches, [(1, 1, true), (2, 0, true), (1, 0, false)]);
        let coverage = gemma_coverage(&conn).unwrap();
        assert_eq!(coverage.embedded_chunks, 4);
        assert_eq!(coverage.skipped_chunks, 1);
        assert!(!coverage.pending);

        // Clean no-op emission without connecting when nothing is pending.
        let mut idle_connects = 0usize;
        let mut idle_batches = Vec::new();
        stream_gemma_with(
            &mut conn,
            32,
            &stop,
            || {
                idle_connects += 1;
                Ok(MockEncoder {
                    calls: 0,
                    on_encode: Box::new(|_, _| Ok(query_vector())),
                })
            },
            |batch| {
                idle_batches.push((batch.new_embeddings, batch.skipped_chunks, batch.has_more));
                Ok(())
            },
        )
        .unwrap();
        assert_eq!(idle_connects, 0);
        assert_eq!(idle_batches, [(0, 0, false)]);

        // Re-seed 3 new documents to verify mid-batch signal termination and scope-change yielding.
        for i in 5..8 {
            fs::write(docs.join(format!("doc-{i}.txt")), format!("Extra {i}")).unwrap();
        }
        drop(conn);
        crate::scan(
            &database,
            &Scope {
                roots: vec![docs.clone()],
                documents: true,
                ..Scope::default()
            },
        )
        .unwrap();
        let (mut conn, _lease) = open_write(&database, false).unwrap();
        let stop_flag = std::sync::Arc::new(AtomicBool::new(false));
        let stop_trigger = stop_flag.clone();
        let mut stopped_batches = Vec::new();
        stream_gemma_with(
            &mut conn,
            2,
            &stop_flag,
            || {
                Ok(MockEncoder {
                    calls: 0,
                    on_encode: Box::new(move |call, _| {
                        if call == 1 {
                            stop_trigger.store(true, Ordering::Release);
                        }
                        Ok(query_vector())
                    }),
                })
            },
            |batch| {
                stopped_batches.push((batch.new_embeddings, batch.skipped_chunks, batch.has_more));
                Ok(())
            },
        )
        .unwrap();
        assert_eq!(stopped_batches, [(1, 0, true)]);
        assert_eq!(gemma_coverage(&conn).unwrap().embedded_chunks, 5);

        // Mutate scope mid-run and confirm the stream yields cleanly without committing stale work.
        let db_for_scope = database.clone();
        let mut scope_batches = Vec::new();
        let stop = AtomicBool::new(false);
        stream_gemma_with(
            &mut conn,
            2,
            &stop,
            || {
                Ok(MockEncoder {
                    calls: 0,
                    on_encode: Box::new(move |_, _| {
                        Connection::open(&db_for_scope)
                            .unwrap()
                            .execute(
                                "UPDATE info SET value=json_set(value,'$.deny',json_array('/tmp/x')) WHERE key='scope'",
                                [],
                            )
                            .unwrap();
                        Ok(query_vector())
                    }),
                })
            },
            |batch| {
                scope_batches.push((batch.new_embeddings, batch.skipped_chunks, batch.has_more));
                Ok(())
            },
        )
        .unwrap();
        assert!(scope_batches.is_empty());
        assert_eq!(gemma_coverage(&conn).unwrap().embedded_chunks, 5);

        drop(conn);
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn gemma_batch_encodes_newest_documents_first_in_one_call() {
        let root = fs::canonicalize(std::env::temp_dir())
            .unwrap()
            .join(format!("lumen-gemma-newest-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        let docs = root.join("docs");
        fs::create_dir_all(&docs).unwrap();
        let day = std::time::Duration::from_secs(86_400);
        // Creation order differs from age order so ids cannot fake recency.
        for (name, age) in [("middle", 2), ("newest", 1), ("oldest", 3)] {
            let path = docs.join(format!("{name}.txt"));
            fs::write(&path, format!("Paragraph {name}")).unwrap();
            let time = std::time::SystemTime::now() - day * age;
            fs::File::options()
                .write(true)
                .open(&path)
                .unwrap()
                .set_times(fs::FileTimes::new().set_accessed(time).set_modified(time))
                .unwrap();
        }
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

        struct BatchEncoder {
            calls: Vec<Vec<String>>,
        }
        impl PassageEncoder for BatchEncoder {
            fn encode_passage(&mut self, _: &str) -> Result<Vec<f32>> {
                unreachable!("batched encoders receive whole groups")
            }
            fn batch_size(&self) -> usize {
                16
            }
            fn encode_passages(&mut self, texts: &[&str]) -> Result<Vec<Option<Vec<f32>>>> {
                self.calls
                    .push(texts.iter().map(|text| text.to_string()).collect());
                Ok(texts
                    .iter()
                    .map(|text| (!text.contains("middle")).then(query_vector))
                    .collect())
            }
        }

        let (mut conn, _lease) = open_write(&database, false).unwrap();
        let mut encoder = BatchEncoder { calls: Vec::new() };
        let (batch, yielded) = embed_gemma_batch(&mut conn, &mut encoder, 8, None, None).unwrap();
        assert!(!yielded);
        assert_eq!(
            encoder.calls,
            [["Paragraph newest", "Paragraph middle", "Paragraph oldest"]]
        );
        assert_eq!((batch.new_embeddings, batch.skipped_chunks), (2, 1));
        let coverage = gemma_coverage(&conn).unwrap();
        assert_eq!((coverage.embedded_chunks, coverage.skipped_chunks), (2, 1));
        assert!(!coverage.pending);

        drop(conn);
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn gemma_corpus_floor_rejects_low_cosine_noise_and_skips_micro_chunks() {
        let root = fs::canonicalize(std::env::temp_dir())
            .unwrap()
            .join(format!("lumen-gemma-noise-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        let docs = root.join("docs");
        fs::create_dir_all(&docs).unwrap();
        for i in 0..8 {
            let text = if i == 0 {
                "附件：\n\n这是一份完整的临床试验受试者筛选标准与伦理说明正文段落。"
            } else {
                "这是一份用于验证无关语义查询下限阈值的标准中文测试文档。"
            };
            fs::write(docs.join(format!("doc-{i}.txt")), text).unwrap();
        }
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
        let mut writer = Connection::open(&database).unwrap();
        while prepare_next_document(&mut writer, true).unwrap() {}

        let make_vec = |cosine: f32| {
            let mut v = vec![0.0_f32; gemma::DIMENSIONS];
            v[0] = cosine;
            v[1] = (1.0 - cosine * cosine).sqrt();
            pack(&v)
        };
        // doc-0 has micro-stub ("附件：", 9B) and substantive paragraph; all other chunks <= 0.74.
        writer
            .execute(
                "INSERT INTO semantic_vector
                 SELECT ?1, c.id, CASE
                     WHEN i.display='doc-0.txt' AND (c.end_byte-c.start_byte) < 24 THEN ?2
                     WHEN i.display='doc-0.txt' THEN ?3
                     ELSE ?4
                 END
                 FROM semantic_chunk c JOIN item i ON i.id=c.document_id",
                params![gemma::ID, make_vec(0.95), make_vec(0.86), make_vec(0.70)],
            )
            .unwrap();

        let mut session = GemmaSearchSession {
            conn: crate::open_read(&database).unwrap(),
            worker: GemmaQuery::Fixture(Box::new(query_vector)),
            matrix: MatrixCache::default(),
            images: None,
        };
        let hits = session.search("临床受试者筛选", 12).unwrap();
        assert_eq!(hits.len(), 1);
        assert_eq!(hits[0].name, "doc-0.txt");
        assert!(
            hits[0]
                .snippet
                .as_deref()
                .is_some_and(|s| s.contains("临床试验受试者筛选标准")),
            "expected substantive paragraph instead of micro-stub, got {:?}",
            hits[0].snippet
        );

        // Now lower doc-0 substantive chunk to noise levels (<= 0.76); even the 0.76 outlier must be rejected.
        writer
            .execute(
                "UPDATE semantic_vector SET vector=?2
                 WHERE chunk_id IN (SELECT c.id FROM semantic_chunk c JOIN item i ON i.id=c.document_id WHERE i.display='doc-0.txt' AND c.end_byte-c.start_byte>=24)",
                params![gemma::ID, make_vec(0.76)],
            )
            .unwrap();
        writer
            .execute(
                "UPDATE semantic_vector SET vector=?1
                 WHERE chunk_id IN (SELECT c.id FROM semantic_chunk c JOIN item i ON i.id=c.document_id WHERE i.display='doc-0.txt' AND c.end_byte-c.start_byte<24)",
                params![make_vec(0.76)],
            )
            .unwrap();
        let noise_hits = session.search("哈基米", 12).unwrap();
        assert!(
            noise_hits.is_empty(),
            "noise hits should be rejected, got {noise_hits:?}"
        );

        drop(session);
        drop(writer);
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn gemma_pending_chunk_maintains_exact_parity_across_lifecycle() {
        let root = fs::canonicalize(std::env::temp_dir())
            .unwrap()
            .join(format!("lumen-gemma-queue-parity-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        let docs = root.join("docs");
        fs::create_dir_all(&docs).unwrap();
        for i in 0..4 {
            fs::write(
                docs.join(format!("doc-{i}.txt")),
                format!("Paragraph {i} with enough content for semantic chunking."),
            )
            .unwrap();
        }
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

        let (mut conn, _lease) = open_write(&database, false).unwrap();
        assert!(has_gemma_pending_queue(&conn).unwrap());

        let assert_parity = |conn: &Connection| {
            let queued: Vec<i64> = conn
                .prepare("SELECT chunk_id FROM gemma_pending_chunk ORDER BY chunk_id")
                .unwrap()
                .query_map([], |r| r.get(0))
                .unwrap()
                .collect::<rusqlite::Result<_>>()
                .unwrap();
            let expected: Vec<i64> = conn
                .prepare(
                    "SELECT c.id FROM semantic_chunk c
                     WHERE NOT EXISTS(
                         SELECT 1 FROM semantic_vector v WHERE v.model=?1 AND v.chunk_id=c.id
                     )
                     ORDER BY c.id",
                )
                .unwrap()
                .query_map([gemma::ID], |r| r.get(0))
                .unwrap()
                .collect::<rusqlite::Result<_>>()
                .unwrap();
            assert_eq!(
                queued, expected,
                "gemma_pending_chunk diverged from ground truth"
            );
            queued
        };

        // Preparing documents populates gemma_pending_chunk via trigger.
        while prepare_next_document(&mut conn, true).unwrap() {}
        let initial = assert_parity(&conn);
        assert_eq!(initial.len(), 4);
        assert!(gemma_pending(&conn).unwrap());

        // Vectors for another model must not clear Gemma's pending queue.
        conn.execute(
            "INSERT INTO semantic_vector(model,chunk_id,vector) VALUES('other-model',?1,zeroblob(3072))",
            [initial[0]],
        )
        .unwrap();
        assert_eq!(assert_parity(&conn), initial);

        // Embedding a partial batch (1 valid + 1 skipped/NULL) removes both from the queue.
        struct PartialEncoder {
            seen: usize,
        }
        impl PassageEncoder for PartialEncoder {
            fn encode_passage(&mut self, _: &str) -> Result<Vec<f32>> {
                self.seen += 1;
                if self.seen == 2 {
                    return Err(Unencodable.into());
                }
                Ok(query_vector())
            }
        }
        let mut encoder = PartialEncoder { seen: 0 };
        let (batch, yielded) = embed_gemma_batch(&mut conn, &mut encoder, 2, None, None).unwrap();
        assert!(!yielded);
        assert_eq!((batch.new_embeddings, batch.skipped_chunks), (1, 1));
        assert_eq!(assert_parity(&conn).len(), 2);

        // Drain the rest of the queue.
        let (batch2, yielded2) = embed_gemma_batch(&mut conn, &mut encoder, 8, None, None).unwrap();
        assert!(!yielded2);
        assert_eq!(batch2.new_embeddings, 2);
        assert!(assert_parity(&conn).is_empty());
        assert!(!gemma_pending(&conn).unwrap());

        // Deleting a vector for gemma::ID re-queues that exact chunk.
        conn.execute(
            "DELETE FROM semantic_vector WHERE model=?1 AND chunk_id=?2",
            params![gemma::ID, initial[0]],
        )
        .unwrap();
        assert_eq!(assert_parity(&conn), vec![initial[0]]);
        assert!(gemma_pending(&conn).unwrap());

        // Deleting an embedded chunk directly must NOT re-insert an orphan via vector-delete cascade.
        conn.execute("DELETE FROM semantic_chunk WHERE id=?1", [initial[1]])
            .unwrap();
        assert_eq!(assert_parity(&conn), vec![initial[0]]);

        // Deleting a document with an embedded chunk cascades cleanly with zero orphans.
        let doc_of_third: i64 = conn
            .query_row(
                "SELECT document_id FROM semantic_chunk WHERE id=?1",
                [initial[2]],
                |r| r.get(0),
            )
            .unwrap();
        conn.execute("DELETE FROM document WHERE id=?1", [doc_of_third])
            .unwrap();
        assert_eq!(assert_parity(&conn), vec![initial[0]]);

        // Deleting the pending chunk clears the queue completely.
        conn.execute("DELETE FROM semantic_chunk WHERE id=?1", [initial[0]])
            .unwrap();
        assert!(assert_parity(&conn).is_empty());
        assert!(!gemma_pending(&conn).unwrap());

        // Stale model marker + stale queue rows are cleanly rebuilt by ensure_gemma_queue.
        conn.execute(
            "UPDATE info SET value='stale-model' WHERE key='gemma_pending_model'",
            [],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO gemma_pending_chunk(chunk_id) VALUES(999999)",
            [],
        )
        .unwrap();
        assert!(!has_gemma_pending_queue(&conn).unwrap());
        ensure_gemma_queue(&conn).unwrap();
        assert!(has_gemma_pending_queue(&conn).unwrap());
        assert!(assert_parity(&conn).is_empty());

        drop(conn);
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn gemma_queue_fast_query_plan_uses_pending_table_without_scanning_all_chunks() {
        let root = fs::canonicalize(std::env::temp_dir())
            .unwrap()
            .join(format!("lumen-gemma-queue-plan-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        let docs = root.join("docs");
        fs::create_dir_all(&docs).unwrap();
        for i in 0..3 {
            fs::write(docs.join(format!("plan-{i}.txt")), format!("Body text {i}")).unwrap();
        }
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

        let (mut conn, _lease) = open_write(&database, false).unwrap();
        assert!(has_gemma_pending_queue(&conn).unwrap());
        while prepare_next_document(&mut conn, true).unwrap() {}

        let explain = |sql: &str, use_params: bool| -> Vec<String> {
            let mut stmt = conn.prepare(&format!("EXPLAIN QUERY PLAN {sql}")).unwrap();
            let extract = |r: &rusqlite::Row<'_>| r.get::<_, String>(3);
            if use_params {
                stmt.query_map(params![0_i64, 16_i64], extract)
                    .unwrap()
                    .collect::<rusqlite::Result<_>>()
                    .unwrap()
            } else {
                stmt.query_map([], extract)
                    .unwrap()
                    .collect::<rusqlite::Result<_>>()
                    .unwrap()
            }
        };

        let fetch_plan = explain(&gemma_queue_fetch_sql(true), true);
        let fetch_joined = fetch_plan.join("\n");
        let pending_idx = fetch_plan
            .iter()
            .position(|line| line.contains("gemma_pending_chunk"))
            .unwrap_or_else(|| {
                panic!("expected fetch plan to drive from gemma_pending_chunk:\n{fetch_joined}")
            });
        let chunk_idx = fetch_plan
            .iter()
            .position(|line| line.contains("SEARCH c USING INTEGER PRIMARY KEY (rowid=?)"))
            .unwrap_or_else(|| {
                panic!("expected point lookup on semantic_chunk c:\n{fetch_joined}")
            });
        assert!(
            pending_idx < chunk_idx,
            "gemma_pending_chunk must drive before semantic_chunk:\n{fetch_joined}"
        );
        assert!(
            !fetch_joined.contains("SCAN c")
                && !fetch_joined.contains("SCAN semantic_chunk")
                && !fetch_joined.contains("SEARCH c USING INTEGER PRIMARY KEY (rowid>?)"),
            "fetch plan must not scan all of semantic_chunk:\n{fetch_joined}"
        );

        let pending_plan = explain(
            &format!("SELECT EXISTS(SELECT 1 {GEMMA_QUEUE_FAST})"),
            false,
        );
        let pending_joined = pending_plan.join("\n");
        let exists_pending_idx = pending_plan
            .iter()
            .position(|line| line.contains("gemma_pending_chunk"))
            .unwrap_or_else(|| {
                panic!("expected pending plan to drive from gemma_pending_chunk:\n{pending_joined}")
            });
        let exists_chunk_idx = pending_plan
            .iter()
            .position(|line| line.contains("SEARCH c USING INTEGER PRIMARY KEY (rowid=?)"))
            .unwrap_or_else(|| {
                panic!("expected point lookup on semantic_chunk c:\n{pending_joined}")
            });
        assert!(
            exists_pending_idx < exists_chunk_idx,
            "gemma_pending_chunk must drive before semantic_chunk:\n{pending_joined}"
        );
        assert!(
            !pending_joined.contains("SCAN c") && !pending_joined.contains("SCAN semantic_chunk"),
            "pending plan must not scan all of semantic_chunk:\n{pending_joined}"
        );

        drop(conn);
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn gemma_queue_falls_back_cleanly_when_pending_table_absent() {
        let root = fs::canonicalize(std::env::temp_dir())
            .unwrap()
            .join(format!("lumen-gemma-queue-fallback-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        let docs = root.join("docs");
        fs::create_dir_all(&docs).unwrap();
        for i in 0..2 {
            fs::write(
                docs.join(format!("fb-{i}.txt")),
                format!("Fallback content {i}"),
            )
            .unwrap();
        }
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

        let (mut conn, _lease) = open_write(&database, false).unwrap();
        while prepare_next_document(&mut conn, true).unwrap() {}
        // Simulate a legacy DB lacking gemma_pending_chunk.
        conn.execute_batch(
            "DROP TRIGGER IF EXISTS gemma_pending_chunk_inserted;
             DROP TRIGGER IF EXISTS gemma_pending_chunk_deleted;
             DROP TRIGGER IF EXISTS gemma_pending_vector_inserted;
             DROP TRIGGER IF EXISTS gemma_pending_vector_deleted;
             DROP TABLE gemma_pending_chunk;
             DELETE FROM info WHERE key='gemma_pending_model';",
        )
        .unwrap();
        assert!(!has_gemma_pending_queue(&conn).unwrap());

        // Read-only connection sees pending=true without needing write access.
        let ro = crate::open_read(&database).unwrap();
        assert!(gemma_pending(&ro).unwrap());
        assert!(gemma_coverage(&ro).unwrap().pending);
        drop(ro);

        // Legacy fallback in embed_gemma_batch still drains and embeds all chunks cleanly.
        struct SimpleEncoder;
        impl PassageEncoder for SimpleEncoder {
            fn encode_passage(&mut self, _: &str) -> Result<Vec<f32>> {
                Ok(query_vector())
            }
        }
        let mut encoder = SimpleEncoder;
        let (batch, yielded) = embed_gemma_batch(&mut conn, &mut encoder, 8, None, None).unwrap();
        assert!(!yielded);
        assert_eq!(batch.new_embeddings, 2);
        assert!(!batch.has_more);
        assert!(!gemma_pending(&conn).unwrap());

        drop(conn);
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn local_openai_coexists_with_gemma_switches_pending_queue_and_decouples_images() {
        use std::{
            io::{BufRead, BufReader, Read, Write},
            net::TcpListener,
            sync::{
                Arc,
                atomic::{AtomicBool, AtomicUsize},
            },
            thread,
        };

        let root = fs::canonicalize(std::env::temp_dir())
            .unwrap()
            .join(format!("lumen-openai-coexist-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        let docs = root.join("docs");
        let media = root.join("media");
        fs::create_dir_all(&docs).unwrap();
        fs::create_dir_all(&media).unwrap();
        let solar = docs.join("solar.txt");
        let finance = docs.join("finance.txt");
        fs::write(
            &solar,
            "Solar panel azimuth and photovoltaic battery guidance.",
        )
        .unwrap();
        fs::write(
            &finance,
            "Quarterly balance sheet and operating margin report.",
        )
        .unwrap();
        let photo = media.join("mountain.png");
        fs::write(&photo, "fake png fixture").unwrap();

        let database = root.join("index.sqlite");
        crate::scan(
            &database,
            &Scope {
                roots: vec![docs.clone(), media.clone()],
                documents: true,
                content_roots: Some(vec![docs.clone()]),
                ..Scope::default()
            },
        )
        .unwrap();
        crate::image_scope(&database, Some(&media)).unwrap();
        crate::index_content(&database, 10).unwrap();

        // Seed built-in Gemma text vectors (768-d) AND Gemma image vector (768-d).
        {
            let (mut conn, _lease) = open_write(&database, false).unwrap();
            while prepare_next_document(&mut conn, true).unwrap() {}
            let mut gemma_vec = vec![0.0_f32; gemma::DIMENSIONS];
            gemma_vec[0] = 1.0;
            conn.execute(
                "INSERT INTO semantic_vector(model,chunk_id,vector)
                 SELECT ?1, c.id, ?2 FROM semantic_chunk c",
                params![gemma::ID, pack(&gemma_vec)],
            )
            .unwrap();
            let stamp = crate::diagnose::local_stamp(&photo, false).unwrap();
            conn.execute(
                "INSERT INTO image_embedding SELECT id,?1,?2,?3 FROM item WHERE path=?4",
                params![
                    crate::IMAGE_MODEL_ID,
                    stamp,
                    pack(&gemma_vec),
                    photo.to_str().unwrap()
                ],
            )
            .unwrap();
            let gcov = gemma_coverage(&conn).unwrap();
            assert_eq!(gcov.embedded_chunks, 2);
            assert!(!gcov.pending);
        }

        // Start a real local loopback OpenAI-compatible mock server serving 16-d vectors.
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        listener.set_nonblocking(true).unwrap();
        let stop_server = Arc::new(AtomicBool::new(false));
        let stop_flag = stop_server.clone();
        let openai_calls = Arc::new(AtomicUsize::new(0));
        let openai_calls_srv = openai_calls.clone();
        let server = thread::spawn(move || {
            while !stop_flag.load(Ordering::Acquire) {
                match listener.accept() {
                    Ok((mut stream, _)) => {
                        stream.set_nonblocking(false).unwrap();
                        let mut reader = BufReader::new(&mut stream);
                        let mut req_line = String::new();
                        if reader.read_line(&mut req_line).unwrap_or(0) == 0 {
                            continue;
                        }
                        let mut content_len = 0usize;
                        loop {
                            let mut line = String::new();
                            reader.read_line(&mut line).unwrap();
                            let trimmed = line.trim_end_matches(['\r', '\n']);
                            if trimmed.is_empty() {
                                break;
                            }
                            if let Some((k, v)) = trimmed.split_once(':')
                                && k.trim().eq_ignore_ascii_case("content-length")
                            {
                                content_len = v.trim().parse().unwrap();
                            }
                        }
                        let mut body = vec![0_u8; content_len];
                        if content_len > 0 {
                            reader.read_exact(&mut body).unwrap();
                        }
                        let _ = reader;
                        openai_calls_srv.fetch_add(1, Ordering::AcqRel);
                        let req: serde_json::Value = serde_json::from_slice(&body).unwrap();
                        let inputs = req["input"].as_array().unwrap();
                        let data: Vec<_> = inputs
                            .iter()
                            .enumerate()
                            .map(|(i, value)| {
                                let text = value.as_str().unwrap_or("");
                                let mut v = vec![0.0_f32; 16];
                                if text.contains("Solar") || text.contains("solar") {
                                    v[0] = 1.0;
                                } else {
                                    v[1] = 1.0;
                                }
                                serde_json::json!({"index": i, "embedding": v})
                            })
                            .collect();
                        let payload =
                            serde_json::to_string(&serde_json::json!({"data": data})).unwrap();
                        let response = format!(
                            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\r\n{}",
                            payload.len(),
                            payload
                        );
                        stream.write_all(response.as_bytes()).unwrap();
                        let _ = stream.flush();
                    }
                    Err(err) if err.kind() == std::io::ErrorKind::WouldBlock => {
                        thread::sleep(std::time::Duration::from_millis(5));
                    }
                    Err(_) => break,
                }
            }
        });

        let config = LocalOpenAiConfig {
            url: format!("http://127.0.0.1:{port}/v1"),
            model: "bge-m3".into(),
        };
        let model_id = "openai-local:bge-m3@16";

        // Before embedding with Local OpenAI, diagnose reports PendingGemma while Gemma is Indexed.
        assert_eq!(
            crate::diagnose(&database, &solar).semantic,
            crate::DiagnoseReason::Indexed
        );
        assert_eq!(
            crate::diagnose_local_openai(&database, &solar, &config)
                .unwrap()
                .semantic,
            crate::DiagnoseReason::PendingGemma
        );

        // Stream embed with Local OpenAI: atomically switches gemma_pending_model without deleting Gemma vectors.
        let stop_embed = AtomicBool::new(false);
        let mut streamed = Vec::new();
        stream_local_openai(&database, &config, 1, &stop_embed, |batch| {
            streamed.push((batch.new_embeddings, batch.skipped_chunks, batch.has_more));
            Ok(())
        })
        .unwrap();
        assert_eq!(streamed, [(1, 0, true), (1, 0, false)]);

        // Re-opening via open_write (like watch/content) must preserve the active openai-local pending queue.
        {
            let (conn, _lease) = open_write(&database, false).unwrap();
            assert!(has_model_pending_queue(&conn, model_id).unwrap());
            let ocov = local_openai_coverage(&conn, model_id, 16).unwrap();
            assert_eq!(ocov.embedded_chunks, 2);
            assert!(!ocov.pending);
            // Coexistence: Gemma's 768-d vectors remain 100% intact!
            let gcov = gemma_coverage(&conn).unwrap();
            assert_eq!(gcov.embedded_chunks, 2);
            assert!(!gcov.pending);
            let status_json = crate::status_with_local_openai(&conn, &config).unwrap();
            assert_eq!(status_json["local_openai"]["model_id"], model_id);
            assert_eq!(status_json["local_openai"]["dimensions"], 16);
            assert_eq!(status_json["gemma"]["embedded_chunks"], 2);
            assert_eq!(status_json["gemma"]["pending"], false);
        }

        // Diagnose now reports Indexed for Local OpenAI as well.
        assert_eq!(
            crate::diagnose_local_openai(&database, &solar, &config)
                .unwrap()
                .semantic,
            crate::DiagnoseReason::Indexed
        );

        // Verify text-vs-image decoupling in GemmaSearchSession:
        // - search() uses 16-d LocalOpenAiWorker against semantic_vector ONLY (never image_embedding)
        // - search_images() uses independent 768-d Gemma image backend against image_embedding ONLY
        let gemma_img_calls = Arc::new(AtomicUsize::new(0));
        let gemma_img_calls_cb = gemma_img_calls.clone();
        let mut session = GemmaSearchSession {
            conn: crate::open_read(&database).unwrap(),
            worker: GemmaQuery::LocalOpenAi {
                worker: LocalOpenAiWorker::new(&config).unwrap(),
                model_id: model_id.into(),
                dims: 16,
                image_backend: LocalOpenAiImageBackend::Fixture(Box::new(move || {
                    gemma_img_calls_cb.fetch_add(1, Ordering::AcqRel);
                    let mut v = vec![0.0_f32; gemma::DIMENSIONS];
                    v[0] = 1.0;
                    v
                })),
            },
            matrix: MatrixCache::default(),
            images: Some(Default::default()),
        };

        let text_hits = session.search("solar panel guidance", 10).unwrap();
        assert_eq!(text_hits.len(), 1);
        assert_eq!(text_hits[0].name, "solar.txt");
        assert_eq!(text_hits[0].matched_by, "semantic_candidate");
        // Image backend was NEVER invoked during text search, and no image hit leaked in!
        assert_eq!(gemma_img_calls.load(Ordering::Acquire), 0);

        let calls_before_img = openai_calls.load(Ordering::Acquire);
        let img_hits = session.search_images("mountain landscape", 10).unwrap();
        assert_eq!(img_hits.len(), 1);
        assert_eq!(img_hits[0].path, photo.to_str().unwrap());
        assert_eq!(img_hits[0].matched_by, "image_embedding");
        // Local OpenAI server was NEVER called for image search; Gemma image backend ran once!
        assert_eq!(openai_calls.load(Ordering::Acquire), calls_before_img);
        assert_eq!(gemma_img_calls.load(Ordering::Acquire), 1);

        // Switching pending queue back to Gemma atomically restores gemma_pending_model.
        {
            let (conn, _lease) = open_write(&database, false).unwrap();
            ensure_gemma_queue(&conn).unwrap();
            assert!(has_gemma_pending_queue(&conn).unwrap());
            assert_eq!(
                local_openai_coverage(&conn, model_id, 16)
                    .unwrap()
                    .embedded_chunks,
                2
            );
            assert_eq!(gemma_coverage(&conn).unwrap().embedded_chunks, 2);
        }

        drop(session);
        stop_server.store(true, Ordering::Release);
        server.join().unwrap();
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn local_openai_dimension_upgrade_and_offline_status_fallback() {
        use std::{
            io::{BufRead, BufReader, Read, Write},
            net::TcpListener,
            sync::{Arc, atomic::AtomicUsize},
            thread,
        };

        let root = std::env::temp_dir().join(format!(
            "lumen-local-openai-dims-{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let docs = root.join("docs");
        fs::create_dir_all(&docs).unwrap();
        let alpha = docs.join("alpha.txt");
        let beta = docs.join("beta.txt");
        fs::write(
            &alpha,
            "Solar photovoltaic array tilt calibration for seasonal maximum output.",
        )
        .unwrap();
        fs::write(
            &beta,
            "Sourdough fermentation schedule with hydration ratios and cold proofing.",
        )
        .unwrap();
        let database = root.join("lumen.sqlite");
        let scope = Scope {
            roots: vec![docs.clone()],
            documents: true,
            ..Scope::default()
        };
        crate::scan(&database, &scope).unwrap();

        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        listener.set_nonblocking(true).unwrap();
        let stop_server = Arc::new(AtomicBool::new(false));
        let stop_flag = stop_server.clone();
        let active_dims = Arc::new(AtomicUsize::new(16));
        let server_dims = active_dims.clone();
        let server = thread::spawn(move || {
            while !stop_flag.load(Ordering::Acquire) {
                match listener.accept() {
                    Ok((mut stream, _)) => {
                        stream.set_nonblocking(false).unwrap();
                        let mut reader = BufReader::new(&mut stream);
                        let mut req_line = String::new();
                        if reader.read_line(&mut req_line).unwrap_or(0) == 0 {
                            continue;
                        }
                        let mut content_len = 0usize;
                        loop {
                            let mut line = String::new();
                            reader.read_line(&mut line).unwrap();
                            let trimmed = line.trim_end_matches(['\r', '\n']);
                            if trimmed.is_empty() {
                                break;
                            }
                            if let Some((k, v)) = trimmed.split_once(':')
                                && k.trim().eq_ignore_ascii_case("content-length")
                            {
                                content_len = v.trim().parse().unwrap();
                            }
                        }
                        let mut body = vec![0_u8; content_len];
                        if content_len > 0 {
                            reader.read_exact(&mut body).unwrap();
                        }
                        let _ = reader;
                        let req: serde_json::Value = serde_json::from_slice(&body).unwrap();
                        let inputs = req["input"].as_array().unwrap();
                        let dims = server_dims.load(Ordering::Acquire);
                        let data: Vec<_> = inputs
                            .iter()
                            .enumerate()
                            .map(|(i, value)| {
                                let text = value.as_str().unwrap_or("");
                                let mut v = vec![0.0_f32; dims];
                                if text.contains("Solar") || text.contains("solar") {
                                    v[0] = 1.0;
                                } else {
                                    v[1] = 1.0;
                                }
                                serde_json::json!({"index": i, "embedding": v})
                            })
                            .collect();
                        let payload =
                            serde_json::to_string(&serde_json::json!({"data": data})).unwrap();
                        let response = format!(
                            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\r\n{}",
                            payload.len(),
                            payload
                        );
                        stream.write_all(response.as_bytes()).unwrap();
                        let _ = stream.flush();
                    }
                    Err(err) if err.kind() == std::io::ErrorKind::WouldBlock => {
                        thread::sleep(Duration::from_millis(5));
                    }
                    Err(_) => break,
                }
            }
        });

        let config = LocalOpenAiConfig {
            url: format!("http://127.0.0.1:{port}/v1"),
            model: "embed-upgrade".into(),
        };

        // 1. Embed at 16d and verify status/search.
        let batch_16 = embed_local_openai_batch(&database, &config, 10).unwrap();
        assert_eq!(batch_16.new_embeddings, 2);
        {
            let conn = crate::open_read(&database).unwrap();
            let status_16 = crate::status_with_local_openai(&conn, &config).unwrap();
            assert_eq!(
                status_16["local_openai"]["model_id"],
                "openai-local:embed-upgrade@16"
            );
            assert_eq!(status_16["local_openai"]["dimensions"], 16);
            assert_eq!(status_16["local_openai"]["coverage"]["embedded_chunks"], 2);
            assert_eq!(status_16["local_openai"]["coverage"]["pending"], false);
        }

        // 2. Upgrade the SAME model name from 16d -> 24d: live probe MUST win over stored @16.
        active_dims.store(24, Ordering::Release);
        {
            let conn = crate::open_read(&database).unwrap();
            let status_24_before = crate::status_with_local_openai(&conn, &config).unwrap();
            assert_eq!(
                status_24_before["local_openai"]["model_id"],
                "openai-local:embed-upgrade@24"
            );
            assert_eq!(status_24_before["local_openai"]["dimensions"], 24);
            assert_eq!(
                status_24_before["local_openai"]["coverage"]["embedded_chunks"],
                0
            );
            assert_eq!(
                status_24_before["local_openai"]["coverage"]["pending"],
                true
            );
        }
        assert_eq!(
            crate::diagnose_local_openai(&database, &alpha, &config)
                .unwrap()
                .semantic,
            crate::DiagnoseReason::PendingGemma
        );

        let batch_24 = embed_local_openai_batch(&database, &config, 10).unwrap();
        assert_eq!(batch_24.new_embeddings, 2);
        {
            let conn = crate::open_read(&database).unwrap();
            let status_24_after = crate::status_with_local_openai(&conn, &config).unwrap();
            assert_eq!(
                status_24_after["local_openai"]["model_id"],
                "openai-local:embed-upgrade@24"
            );
            assert_eq!(status_24_after["local_openai"]["dimensions"], 24);
            assert_eq!(
                status_24_after["local_openai"]["coverage"]["embedded_chunks"],
                2
            );
            assert_eq!(
                status_24_after["local_openai"]["coverage"]["pending"],
                false
            );
        }
        let mut session_24 =
            GemmaSearchSession::open_local_openai(&database, &config, None).unwrap();
        assert_eq!(
            session_24.search("solar panel tilt", 5).unwrap()[0].name,
            "alpha.txt"
        );
        drop(session_24);

        // 3. Switch back 24d -> 16d (and via localhost URL): reuses existing @16 vectors cleanly!
        active_dims.store(16, Ordering::Release);
        let localhost_config = LocalOpenAiConfig {
            url: format!("http://localhost:{port}/v1"),
            model: "embed-upgrade".into(),
        };
        {
            let conn = crate::open_read(&database).unwrap();
            let status_back_16 = crate::status_with_local_openai(&conn, &localhost_config).unwrap();
            assert_eq!(
                status_back_16["local_openai"]["model_id"],
                "openai-local:embed-upgrade@16"
            );
            assert_eq!(status_back_16["local_openai"]["dimensions"], 16);
            assert_eq!(
                status_back_16["local_openai"]["coverage"]["embedded_chunks"],
                2
            );
            assert_eq!(status_back_16["local_openai"]["coverage"]["pending"], false);
        }
        let reuse_batch = embed_local_openai_batch(&database, &localhost_config, 10).unwrap();
        assert_eq!(reuse_batch.new_embeddings, 0);
        let mut session_16 =
            GemmaSearchSession::open_local_openai(&database, &localhost_config, None).unwrap();
        assert_eq!(
            session_16.search("solar panel tilt", 5).unwrap()[0].name,
            "alpha.txt"
        );
        drop(session_16);

        // 4. Stop server: status_with_local_openai MUST fall back cleanly to read-only stored coverage
        //    even when loopback HTTP is offline, Unix socket is missing, or URL is misconfigured.
        stop_server.store(true, Ordering::Release);
        server.join().unwrap();
        {
            let conn = crate::open_read(&database).unwrap();
            let offline_http = crate::status_with_local_openai(&conn, &config).unwrap();
            assert_eq!(
                offline_http["local_openai"]["model_id"],
                "openai-local:embed-upgrade@16"
            );
            assert_eq!(offline_http["local_openai"]["dimensions"], 16);
            assert_eq!(
                offline_http["local_openai"]["coverage"]["embedded_chunks"],
                2
            );

            let missing_sock = LocalOpenAiConfig {
                url: format!("unix://{}", root.join("stopped.sock").display()),
                model: "embed-upgrade".into(),
            };
            let offline_unix = crate::status_with_local_openai(&conn, &missing_sock).unwrap();
            assert_eq!(
                offline_unix["local_openai"]["model_id"],
                "openai-local:embed-upgrade@16"
            );
            assert_eq!(offline_unix["local_openai"]["dimensions"], 16);

            let invalid_cfg = LocalOpenAiConfig {
                url: "https://api.openai.com/v1".into(),
                model: "never-indexed".into(),
            };
            let degraded = crate::status_with_local_openai(&conn, &invalid_cfg).unwrap();
            assert_eq!(degraded["documents"], 2);
            assert!(degraded["local_openai"]["model_id"].is_null());
            assert!(degraded["local_openai"]["dimensions"].is_null());
            assert_eq!(degraded["local_openai"]["coverage"]["embedded_chunks"], 0);
            assert_eq!(degraded["local_openai"]["coverage"]["pending"], true);
        }

        fs::remove_dir_all(root).unwrap();
    }
}
