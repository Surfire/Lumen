//! Independent local index. The CLI and native launcher share this implementation.
mod diagnose;
mod docx;
mod gemma;
mod index;
mod model;
mod name_fast;
mod platform;
mod progress;
mod semantic;
mod watch;

pub use diagnose::{Diagnosis, Reason as DiagnoseReason, diagnose};
pub use gemma::{GemmaModel, ID as GEMMA_MODEL_ID};
pub use index::{scan, scan_with_progress};
pub use model::{BgeModel, Model, ModelBackend};
pub use progress::{ScanPhase, ScanProgress, ScanProgressReporter};
pub use semantic::{
    EmbedBatch, GemmaCoverage, GemmaSearchSession, embed, embed_batch, embed_with_backend,
    gemma_coverage,
};
pub use watch::{WatchEvent, watch, watch_with_progress};

use anyhow::{Context, Result, bail};
use rusqlite::{Connection, OpenFlags, OptionalExtension, params};
use serde::{Deserialize, Serialize};
use std::{
    fs,
    os::unix::fs::PermissionsExt,
    path::{Path, PathBuf},
    time::Duration,
};
use unicode_normalization::UnicodeNormalization;

pub const MAX_DOCUMENT: u64 = 2 * 1024 * 1024;
const SCHEMA_VERSION: i64 = 1;
const DATABASE_APPLICATION_ID: i64 = 0x4c554d4e; // LUMN

pub fn standard_database() -> PathBuf {
    let home = std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(std::env::temp_dir);
    home.join("Library/Application Support/Lumen/index.sqlite")
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Scope {
    pub roots: Vec<PathBuf>,
    pub allow: Vec<PathBuf>,
    pub deny: Vec<PathBuf>,
    pub documents: bool,
    pub pdf_helper: Option<PathBuf>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pdf_helper_policy: Option<PdfHelperPolicy>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PdfHelperPolicy {
    Manual,
    Bundled,
}

impl Scope {
    #[cfg(target_os = "macos")]
    fn unspecified(&self) -> bool {
        self.roots.is_empty()
            && self.allow.is_empty()
            && self.deny.is_empty()
            && !self.documents
            && self.pdf_helper.is_none()
    }

    pub fn roots(&self) -> Vec<PathBuf> {
        if !self.roots.is_empty() {
            self.roots.clone()
        } else if !self.allow.is_empty() {
            self.allow.clone()
        } else {
            vec![PathBuf::from("/")]
        }
    }

    pub fn allows(&self, path: &Path) -> bool {
        !self.excludes(path)
            && (self.allow.is_empty()
                || self
                    .allow
                    .iter()
                    .any(|p| path.starts_with(p) || p.starts_with(path)))
    }

    fn excludes(&self, path: &Path) -> bool {
        self.deny.iter().any(|p| platform::denied_by(path, p))
            || sensitive_path(path)
            || (system_path(path)
                && !self
                    .roots
                    .iter()
                    .any(|root| is_temp_path(root) && path.starts_with(root)))
            || (path.starts_with("/Volumes")
                && !self
                    .roots
                    .iter()
                    .any(|root| root.starts_with("/Volumes") && path.starts_with(root)))
    }
}

fn is_temp_path(path: &Path) -> bool {
    [
        "/tmp",
        "/private/tmp",
        "/var/folders",
        "/private/var/folders",
    ]
    .iter()
    .any(|p| path.starts_with(p))
}
fn system_path(path: &Path) -> bool {
    [
        "/System",
        "/dev",
        "/private/var",
        "/private/etc",
        "/private/tmp",
        "/cores",
        "/Network",
    ]
    .iter()
    .any(|p| path.starts_with(p))
}
fn sensitive_path(path: &Path) -> bool {
    path.components().any(|part| {
        part.as_os_str().to_str().is_some_and(|p| {
            p.starts_with('.')
                || ["keychains", "cookies", "caches"]
                    .iter()
                    .any(|name| p.eq_ignore_ascii_case(name))
        })
    })
}

fn norm(text: &str) -> String {
    if text.is_ascii() {
        text.to_ascii_lowercase()
    } else {
        text.nfkc().flat_map(char::to_lowercase).collect()
    }
}

fn fts_phrase(text: &str) -> String {
    format!("\"{}\"", text.replace('"', "\"\""))
}

fn secure_dir(path: &Path) -> Result<()> {
    #[cfg(unix)]
    use std::os::unix::fs::DirBuilderExt;
    if !path.exists() {
        fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(path)?;
    }
    if !fs::symlink_metadata(path)?.is_dir() {
        bail!("index directory is not a regular directory");
    }
    Ok(())
}

fn with_suffix(path: &Path, suffix: &str) -> PathBuf {
    let mut name = path.as_os_str().to_owned();
    name.push(suffix);
    PathBuf::from(name)
}

fn open_private_file(path: &Path) -> Result<fs::File> {
    use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
    // Create with restrictive permissions before SQLite creates WAL side files.
    #[cfg(target_os = "macos")]
    let flags = libc::O_NOFOLLOW_ANY;
    #[cfg(not(target_os = "macos"))]
    let flags = libc::O_NOFOLLOW;
    let file = fs::OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .mode(0o600)
        .custom_flags(flags)
        .open(path)?;
    let metadata = file.metadata()?;
    if !metadata.is_file()
        || metadata.nlink() != 1
        || metadata.uid() != unsafe { libc::geteuid() }
        || metadata.permissions().mode() & 0o077 != 0
    {
        bail!("index must be a user-only regular file (0600)");
    }
    Ok(file)
}

fn open_write(path: &Path, exclusive_indexer: bool) -> Result<(Connection, Option<fs::File>)> {
    use std::os::fd::AsRawFd;
    if let Some(parent) = path.parent().filter(|p| !p.as_os_str().is_empty()) {
        secure_dir(parent)?;
    }
    // Darwin flock on the database itself conflicts with SQLite's locks.
    let lease = if exclusive_indexer {
        let lock = open_private_file(&with_suffix(path, "-watch-lock"))
            .context("open index writer lease")?;
        if unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
            return Err(std::io::Error::last_os_error()).context(
                "cannot acquire index writer lease; another index or watch may be running",
            );
        }
        Some(lock)
    } else {
        None
    };
    let metadata = open_private_file(path)?.metadata()?;
    let conn = Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_WRITE)?;
    conn.busy_timeout(Duration::from_secs(5))?;
    let version: i64 = conn.pragma_query_value(None, "user_version", |row| row.get(0))?;
    let id: i64 = conn.pragma_query_value(None, "application_id", |row| row.get(0))?;
    if !(id == DATABASE_APPLICATION_ID && version == SCHEMA_VERSION
        || id == 0 && version == 0 && metadata.len() == 0)
    {
        bail!("not a supported Lumen index; no changes made");
    }
    conn.execute_batch(
        "
        PRAGMA journal_mode=WAL;
        PRAGMA synchronous=NORMAL;
        BEGIN;
        PRAGMA application_id=0x4c554d4e;
        PRAGMA user_version=1;
        CREATE TABLE IF NOT EXISTS item(
          id INTEGER PRIMARY KEY, path TEXT NOT NULL UNIQUE, display TEXT NOT NULL,
          kind TEXT NOT NULL, availability TEXT NOT NULL, name TEXT NOT NULL,
          full TEXT NOT NULL, initials TEXT NOT NULL, searchable_path TEXT NOT NULL
        );
        CREATE VIRTUAL TABLE IF NOT EXISTS name_fts USING fts5(name,full,initials,searchable_path,
          tokenize='trigram');
        CREATE TABLE IF NOT EXISTS document(id INTEGER PRIMARY KEY, body TEXT NOT NULL,
          normalized TEXT NOT NULL);
        CREATE VIRTUAL TABLE IF NOT EXISTS content_fts USING fts5(body, tokenize='trigram');
        CREATE TABLE IF NOT EXISTS embedding(id INTEGER PRIMARY KEY, vector BLOB NOT NULL);
        CREATE TABLE IF NOT EXISTS info(key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS document_state(id INTEGER PRIMARY KEY, stamp TEXT NOT NULL);
    ",
    )?;
    if !semantic::installed(&conn)? {
        conn.execute_batch(semantic::SCHEMA)?;
    }
    conn.execute_batch(semantic::SKIP_SCHEMA)?;
    conn.execute_batch(semantic::VERSIONED_SCHEMA)?;
    conn.execute_batch("COMMIT;")?;
    Ok((conn, lease))
}

pub fn open_read(path: &Path) -> Result<Connection> {
    let path = absolute(path)?;
    if !fs::symlink_metadata(&path)?.is_file() {
        bail!("index is not a regular file");
    }
    let connection = Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY)?;
    connection.busy_timeout(Duration::from_secs(3))?;
    let version: i64 = connection.pragma_query_value(None, "user_version", |r| r.get(0))?;
    let id: i64 = connection.pragma_query_value(None, "application_id", |r| r.get(0))?;
    if version != SCHEMA_VERSION || id != DATABASE_APPLICATION_ID {
        bail!("no supported index was found");
    }
    Ok(connection)
}

#[derive(Debug, Default, Serialize)]
pub struct ScanStats {
    pub roots: Vec<String>,
    pub items: u64,
    pub skipped: u64,
    pub entries_unreadable: u64,
    pub bulk_directories: u64,
    pub fallback_directories: u64,
    pub provider_metadata_only: u64,
    pub placeholders: u64,
    pub documents: u64,
    pub documents_not_read: u64,
    pub elapsed_ms: u128,
}

fn absolute(p: &Path) -> Result<PathBuf> {
    use std::path::Component::*;
    let p = if p.is_absolute() {
        p.to_path_buf()
    } else {
        std::env::current_dir()?.join(p)
    };
    let mut normalized = PathBuf::new();
    for c in p.components() {
        match c {
            ParentDir => {
                normalized.pop();
            }
            CurDir => {}
            value => normalized.push(value.as_os_str()),
        }
    }
    // Canonicalize /tmp on macOS for developer fixture paths without following arbitrary links.
    #[cfg(target_os = "macos")]
    for prefix in ["/tmp", "/var"] {
        if let Ok(rest) = normalized.strip_prefix(prefix) {
            return Ok(PathBuf::from(format!("/private{prefix}")).join(rest));
        }
    }
    Ok(normalized)
}

#[derive(Clone, Copy, Debug, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum Mode {
    #[default]
    Name,
    Text,
    Semantic,
    All,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct Hit {
    pub path: String,
    pub name: String,
    pub kind: String,
    pub availability: String,
    pub matched_by: String,
    pub snippet: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub document_stamp: Option<String>,
    pub score: Option<f64>,
}

fn row_hit(row: &rusqlite::Row<'_>, reason: &str) -> rusqlite::Result<Hit> {
    Ok(Hit {
        path: row.get(0)?,
        name: row.get(1)?,
        kind: row.get(2)?,
        availability: row.get(3)?,
        matched_by: reason.to_string(),
        snippet: None,
        document_stamp: None,
        score: None,
    })
}

fn document_stamp_sql(conn: &Connection) -> rusqlite::Result<(&'static str, &'static str)> {
    let has_state: bool = conn
        .prepare_cached("SELECT EXISTS(SELECT 1 FROM sqlite_schema WHERE type='table' AND name='document_state')")?
        .query_row([], |r| r.get(0))?;
    if has_state {
        Ok(("ds.stamp", "LEFT JOIN document_state ds ON ds.id=d.id"))
    } else {
        Ok(("NULL", ""))
    }
}

fn read_document_stamp(row: &rusqlite::Row<'_>) -> rusqlite::Result<Option<String>> {
    let stamp: Option<String> = row.get("document_stamp")?;
    Ok(stamp.and_then(|mut stamp| {
        // The index may append an extractor version or a helper signature.
        // The client compares just the seven fields from filesystem metadata.
        if let Some((end, _)) = stamp.match_indices(':').nth(6) {
            stamp.truncate(end);
        }
        (stamp.split(':').count() == 7 && stamp.split(':').all(|part| part.parse::<i128>().is_ok()))
            .then_some(stamp)
    }))
}

fn short_snippet(text: &str, query: &str) -> String {
    let start = text
        .find(query)
        .filter(|i| text.is_char_boundary(*i))
        .map(|i| {
            text.char_indices()
                .take_while(|(offset, _)| *offset < i)
                .count()
                .saturating_sub(28)
        })
        .unwrap_or_else(|| {
            let qchars = query.chars().count();
            let sample: Vec<char> = text.chars().take(8192).collect();
            sample
                .windows(qchars.max(1))
                .position(|xs| norm(&xs.iter().collect::<String>()) == query)
                .map(|i| i.saturating_sub(28))
                .unwrap_or(0)
        });
    text.chars().skip(start).take(110).collect()
}

pub fn search(
    conn: &Connection,
    query: &str,
    mode: Mode,
    limit: usize,
    model: Option<&Model>,
) -> Result<Vec<Hit>> {
    search_with_backend(conn, query, mode, limit, model.map(ModelBackend::Helper))
}

pub fn search_with_backend(
    conn: &Connection,
    query: &str,
    mode: Mode,
    limit: usize,
    model: Option<ModelBackend<'_>>,
) -> Result<Vec<Hit>> {
    search_with_names(conn, query, mode, limit, model, None)
}

/// A persistent reader for the native launcher's request stream.
pub struct SearchSession {
    conn: Connection,
    names: name_fast::NameFast,
}

impl SearchSession {
    pub fn open(path: &Path) -> Result<Self> {
        let path = absolute(path)?;
        let conn = open_read(&path)?;
        let names = name_fast::NameFast::new(&path, &conn);
        Ok(Self { conn, names })
    }

    pub fn search(&mut self, query: &str, mode: Mode, limit: usize) -> Result<Vec<Hit>> {
        search_with_names(&self.conn, query, mode, limit, None, Some(&mut self.names))
    }
}

fn search_with_names(
    conn: &Connection,
    query: &str,
    mode: Mode,
    limit: usize,
    model: Option<ModelBackend<'_>>,
    names: Option<&mut name_fast::NameFast>,
) -> Result<Vec<Hit>> {
    let q = norm(query.trim());
    if q.is_empty() || q.len() > 512 {
        return Ok(vec![]);
    }
    let limit = limit.clamp(1, 100);
    let cached = if matches!(mode, Mode::Name | Mode::All) {
        match names {
            Some(names) => names.search(conn, &q, limit)?,
            None => None,
        }
    } else {
        None
    };
    let (version, mut hits) = cached.map_or((None, Vec::new()), |(v, hits)| (Some(v), hits));
    if version.is_none() && matches!(mode, Mode::Name | Mode::All) {
        hits = name_fast::search_disk(conn, &q, limit)?;
    }
    let mut seen = std::collections::HashSet::new();
    if mode == Mode::All && hits.len() < limit {
        seen.extend(hits.iter().map(|hit| hit.path.clone()));
    }
    if matches!(mode, Mode::Text | Mode::All) && hits.len() < limit {
        let (stamp, state_join) = document_stamp_sql(conn)?;
        let sql = if q.chars().count() >= 3 {
            format!("SELECT i.path,i.display,i.kind,i.availability,d.body,{stamp} AS document_stamp
                     FROM content_fts JOIN item i ON i.id=content_fts.rowid JOIN document d ON d.id=i.id
                     {state_join} WHERE content_fts MATCH ?1 AND ?2 IS NOT NULL
                     AND i.availability<>'unverified' ORDER BY rank,i.path LIMIT ?3")
        } else {
            format!(
                "SELECT i.path,i.display,i.kind,i.availability,d.body,{stamp} AS document_stamp
                     FROM document d JOIN item i ON i.id=d.id
                     {state_join} WHERE ?1 IS NOT NULL AND instr(d.normalized,?2)>0
                     AND i.availability<>'unverified' ORDER BY i.path LIMIT ?3"
            )
        };
        let mut stmt = conn.prepare_cached(&sql)?;
        let rows = stmt.query_map(params![fts_phrase(&q), q, limit as i64], |r| {
            let mut h = row_hit(r, "text")?;
            let text: String = r.get(4)?;
            h.snippet = Some(short_snippet(&text, &q));
            h.document_stamp = read_document_stamp(r)?;
            Ok(h)
        })?;
        for hit in rows {
            let h = hit?;
            if seen.insert(h.path.clone()) {
                hits.push(h);
            }
            if hits.len() == limit {
                break;
            }
        }
    }
    if matches!(mode, Mode::Semantic | Mode::All) && hits.len() < limit {
        if let Some(model) = model {
            for hit in semantic::search(conn, query, limit, model)? {
                if seen.insert(hit.path.clone()) {
                    hits.push(hit);
                }
                if hits.len() == limit {
                    break;
                }
            }
        } else if mode == Mode::Semantic {
            bail!("semantic mode requires a local model helper");
        }
    }
    if let Some(version) = version {
        // A concurrent indexer may commit while computing names or combining
        // them with text. Discard that result and read SQLite's current view.
        if version != name_fast::data_version(conn)? {
            return search_with_backend(conn, query, mode, limit, model);
        }
    }
    Ok(hits)
}

/// Return complete saved scope rules only. Older or malformed indexes have no
/// authority to provide defaults for an exact-scope rebuild.
pub fn saved_index_scope(conn: &Connection) -> Result<Option<Scope>> {
    let stored: Option<String> = conn
        .query_row("SELECT value FROM info WHERE key='scope'", [], |row| {
            row.get(0)
        })
        .optional()?;
    Ok(stored
        .as_deref()
        .and_then(|scope| serde_json::from_str::<Scope>(scope).ok())
        .filter(|scope| {
            !scope.roots.is_empty()
                && scope
                    .roots
                    .iter()
                    .chain(&scope.allow)
                    .chain(&scope.deny)
                    .all(|path| {
                        path.is_absolute()
                            && !path
                                .components()
                                .any(|part| part == std::path::Component::ParentDir)
                    })
        }))
}

pub fn status(conn: &Connection) -> Result<serde_json::Value> {
    let text: String =
        conn.query_row("SELECT value FROM info WHERE key='scan'", [], |r| r.get(0))?;
    let mut data: serde_json::Value = serde_json::from_str(&text)?;
    let (items, documents, unverified) = conn.query_row(
        "SELECT
             (SELECT count(*) FROM item WHERE availability<>'unverified'),
             (SELECT count(*) FROM document JOIN item USING(id) WHERE availability<>'unverified'),
             (SELECT count(*) FROM item WHERE availability='unverified')",
        [],
        |r| {
            Ok((
                r.get::<_, i64>(0)?,
                r.get::<_, i64>(1)?,
                r.get::<_, i64>(2)?,
            ))
        },
    )?;
    data["items"] = items.into();
    data["documents"] = documents.into();
    semantic::add_status(conn, &mut data)?;
    data["unverified"] = unverified.into();
    Ok(data)
}
