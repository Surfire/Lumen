//! Independent local index. The CLI and native launcher share this implementation.
mod platform;

use anyhow::{Context, Result, bail};
use rusqlite::{Connection, OpenFlags, OptionalExtension, params};
use serde::{Deserialize, Serialize};
use std::{
    collections::HashMap,
    fs,
    io::Write,
    os::unix::fs::PermissionsExt,
    path::{Path, PathBuf},
    process::{Command, Stdio},
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

#[derive(Debug, Default)]
pub struct Scope {
    pub roots: Vec<PathBuf>,
    pub allow: Vec<PathBuf>,
    pub deny: Vec<PathBuf>,
    pub documents: bool,
    pub pdf_helper: Option<PathBuf>,
}

impl Scope {
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
        // Deny always wins, including when allow contains a descendant.
        !self.deny.iter().any(|p| path.starts_with(p))
            && (self.allow.is_empty()
                || self
                    .allow
                    .iter()
                    .any(|p| path.starts_with(p) || p.starts_with(path)))
            && !sensitive_path(path)
            && (!system_path(path)
                || self
                    .roots
                    .iter()
                    .any(|root| is_temp_path(root) && path.starts_with(root)))
            && (!path.starts_with("/Volumes")
                || self
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
                || matches!(
                    p.to_ascii_lowercase().as_str(),
                    "keychains" | "cookies" | "caches"
                )
        })
    })
}

fn norm(text: &str) -> String {
    text.nfkc().flat_map(char::to_lowercase).collect()
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

fn open_write(path: &Path) -> Result<Connection> {
    use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
    if let Some(parent) = path.parent().filter(|p| !p.as_os_str().is_empty()) {
        secure_dir(parent)?;
    }
    // Create with restrictive permissions before SQLite creates WAL side files.
    let flags = if cfg!(target_os = "macos") {
        #[cfg(target_os = "macos")]
        {
            libc::O_NOFOLLOW_ANY
        }
        #[cfg(not(target_os = "macos"))]
        {
            libc::O_NOFOLLOW
        }
    } else {
        libc::O_NOFOLLOW
    };
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
        COMMIT;
    ",
    )?;
    Ok(conn)
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

pub fn scan(database: &Path, scope: &Scope) -> Result<ScanStats> {
    let start = std::time::Instant::now();
    #[cfg(target_os = "macos")]
    let _io = platform::NoMaterialization::enter()?;
    let scope = Scope {
        roots: scope
            .roots()
            .iter()
            .map(|p| absolute(p))
            .collect::<Result<_>>()?,
        allow: scope
            .allow
            .iter()
            .map(|p| absolute(p))
            .collect::<Result<_>>()?,
        deny: scope
            .deny
            .iter()
            .map(|p| absolute(p))
            .collect::<Result<_>>()?,
        documents: scope.documents,
        pdf_helper: scope.pdf_helper.clone(),
    };
    let file = absolute(database)?;
    let mut connection = open_write(&file)?;
    let tx = connection.transaction()?;
    tx.execute_batch("DELETE FROM item; DELETE FROM name_fts; DELETE FROM document; DELETE FROM content_fts; DELETE FROM embedding; DELETE FROM info;")?;
    let mut stats = ScanStats {
        roots: scope
            .roots
            .iter()
            .map(|p| p.display().to_string())
            .collect(),
        ..ScanStats::default()
    };
    let sidecars = ["-wal", "-shm", "-journal"].map(|suffix| {
        let mut path = file.as_os_str().to_owned();
        path.push(suffix);
        PathBuf::from(path)
    });
    let mut seen = std::collections::HashSet::new();
    let mut readable_roots = 0;
    let mut update_pinyin = HashMap::<String, (String, String)>::new();
    {
        let mut item = tx.prepare("INSERT INTO item(path,display,kind,availability,name,full,initials,searchable_path) VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(path) DO NOTHING RETURNING id")?;
        let mut names = tx.prepare(
            "INSERT INTO name_fts(rowid,name,full,initials,searchable_path) VALUES(?,?,?,?,?)",
        )?;
        let mut documents = tx.prepare("INSERT INTO document(id,body,normalized) VALUES(?,?,?)")?;
        let mut content = tx.prepare("INSERT INTO content_fts(rowid,body) VALUES(?,?)")?;
        let mut work = scope
            .roots
            .iter()
            .cloned()
            .map(|p| (p, true, None))
            .collect::<Vec<_>>();
        while let Some((path, root, cached)) = work.pop() {
            use std::os::unix::fs::MetadataExt;
            let is_database_file = path == file || sidecars.contains(&path);
            if !scope.allows(&path)
                || is_database_file
                || file
                    .parent()
                    .is_some_and(|p| path.starts_with(p) && p.ends_with("Lumen"))
            {
                stats.skipped += 1;
                continue;
            }
            let (is_dir, availability, dir_id) = match cached {
                Some(Some(platform::FastInfo {
                    directory: false,
                    dataless,
                })) => (false, platform::classify(&path, dataless), None),
                _ => {
                    let meta = match fs::symlink_metadata(&path) {
                        Ok(v) => v,
                        Err(_) => {
                            stats.entries_unreadable += 1;
                            continue;
                        }
                    };
                    if meta.file_type().is_symlink() || (!meta.is_file() && !meta.is_dir()) {
                        stats.skipped += 1;
                        continue;
                    }
                    (
                        meta.is_dir(),
                        platform::availability(&path, &meta),
                        Some((meta.dev(), meta.ino())),
                    )
                }
            };
            if root && is_dir && availability != "placeholder" {
                readable_roots += 1;
            }
            let Some(path_text) = path.to_str() else {
                stats.skipped += 1;
                continue;
            };
            if availability == "placeholder" {
                stats.placeholders += 1;
            }
            if availability == "provider_metadata_only" {
                stats.provider_metadata_only += 1;
            }
            if path != Path::new("/") {
                let display = path
                    .file_name()
                    .and_then(|p| p.to_str())
                    .unwrap_or(path_text);
                let name = norm(display);
                // Bound auxiliary memory for large volumes.
                if update_pinyin.len() >= 4096 {
                    update_pinyin.clear();
                }
                let (full, initials) = update_pinyin
                    .entry(display.to_owned())
                    .or_insert_with(|| platform::pinyin(display));
                let searchable_path = norm(path_text);
                if let Some(id) = item
                    .query_row(
                        params![
                            path_text,
                            display,
                            if is_dir { "directory" } else { "file" },
                            availability,
                            name,
                            full.as_str(),
                            initials.as_str(),
                            searchable_path
                        ],
                        |row| row.get::<_, i64>(0),
                    )
                    .optional()?
                {
                    names.execute(params![
                        id,
                        name,
                        full.as_str(),
                        initials.as_str(),
                        searchable_path
                    ])?;
                    stats.items += 1;
                    let ext = path
                        .extension()
                        .and_then(|e| e.to_str())
                        .map(str::to_ascii_lowercase);
                    let plain = matches!(ext.as_deref(), Some("txt" | "md" | "markdown"));
                    let pdf = matches!(ext.as_deref(), Some("pdf")) && scope.pdf_helper.is_some();
                    if scope.documents && !is_dir && (plain || pdf) {
                        let body = if pdf {
                            platform::read_local(&path, 24 * 1024 * 1024).and_then(|bytes| {
                                let helper =
                                    scope.pdf_helper.as_ref().expect("PDF helper configured");
                                let mut child = Command::new(helper)
                                    .stdin(Stdio::piped())
                                    .stdout(Stdio::piped())
                                    .stderr(Stdio::null())
                                    .spawn()?;
                                // Write and read concurrently so a parser that emits partial
                                // output before consuming input cannot deadlock both pipes.
                                let mut input = child.stdin.take().context("extractor input")?;
                                let writer = std::thread::spawn(move || input.write_all(&bytes));
                                let output = child.wait_with_output()?;
                                writer
                                    .join()
                                    .map_err(|_| anyhow::anyhow!("extractor input failed"))??;
                                if !output.status.success()
                                    || output.stdout.len() as u64 > MAX_DOCUMENT
                                {
                                    bail!("PDF extraction failed or exceeded text limit");
                                }
                                Ok(String::from_utf8(output.stdout)?)
                            })
                        } else {
                            platform::read_local(&path, MAX_DOCUMENT)
                                .and_then(|bytes| Ok(String::from_utf8(bytes)?))
                        };
                        match body {
                            Ok(body) if !body.is_empty() => {
                                let n = norm(&body);
                                documents.execute(params![id, body, n])?;
                                content.execute(params![id, n])?;
                                stats.documents += 1;
                            }
                            _ => stats.documents_not_read += 1,
                        }
                    }
                }
            }
            if is_dir {
                // Do not request children from dataless directories.
                if availability == "placeholder" {
                    stats.skipped += 1;
                    continue;
                }
                // Detect directory aliases, duplicate roots and APFS alternate paths.
                if !seen.insert(dir_id.expect("directory metadata available")) && !root {
                    continue;
                }
                if let Some(children) = platform::bulk_children(&path) {
                    stats.bulk_directories += 1;
                    work.extend(
                        children
                            .into_iter()
                            .map(|(child, info)| (path.join(child), false, Some(info))),
                    );
                    continue;
                }
                stats.fallback_directories += 1;
                match fs::read_dir(&path) {
                    Ok(dir) => {
                        for e in dir {
                            match e {
                                Ok(e) => work.push((e.path(), false, None)),
                                Err(_) => stats.entries_unreadable += 1,
                            }
                        }
                    }
                    Err(_) => stats.entries_unreadable += 1,
                }
            }
        }
    }
    if readable_roots == 0 {
        bail!("none of the requested roots were readable; previous index is unchanged");
    }
    stats.elapsed_ms = start.elapsed().as_millis();
    tx.execute(
        "INSERT INTO info(key,value) VALUES('scan',?)",
        [serde_json::to_string(&stats)?],
    )?;
    tx.commit()?;
    Ok(stats)
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
        score: None,
    })
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
    let q = norm(query.trim());
    if q.is_empty() || q.len() > 512 {
        return Ok(vec![]);
    }
    let limit = limit.clamp(1, 100);
    let mut hits = Vec::new();
    let mut seen = std::collections::HashSet::new();
    if matches!(mode, Mode::Name | Mode::All) {
        let sql_long = "SELECT i.path,i.display,i.kind,i.availability,CASE WHEN instr(i.name,?2)>0 THEN 'name' WHEN instr(i.full,?2)>0 OR instr(i.initials,?2)>0 THEN 'pinyin' ELSE 'path' END FROM name_fts JOIN item i ON i.id=name_fts.rowid WHERE name_fts MATCH ?1 ORDER BY CASE WHEN i.name=?2 THEN 0 WHEN instr(i.name,?2)=1 THEN 1 WHEN instr(i.name,?2)>0 THEN 2 WHEN instr(i.full,?2)>0 OR instr(i.initials,?2)>0 THEN 3 ELSE 4 END,length(i.display),i.path LIMIT ?3";
        let sql_short = "SELECT i.path,i.display,i.kind,i.availability,CASE WHEN instr(i.name,?2)>0 THEN 'name' WHEN instr(i.full,?2)>0 OR instr(i.initials,?2)>0 THEN 'pinyin' ELSE 'path' END FROM item i WHERE ?1 IS NOT NULL AND (instr(i.name,?2)>0 OR instr(i.full,?2)>0 OR instr(i.initials,?2)>0 OR instr(i.searchable_path,?2)>0) ORDER BY CASE WHEN i.name=?2 THEN 0 WHEN instr(i.name,?2)=1 THEN 1 WHEN instr(i.name,?2)>0 THEN 2 WHEN instr(i.full,?2)>0 OR instr(i.initials,?2)>0 THEN 3 ELSE 4 END,length(i.display),i.path LIMIT ?3";
        let mut stmt = conn.prepare_cached(if q.chars().count() >= 3 {
            sql_long
        } else {
            sql_short
        })?;
        let rows = stmt.query_map(params![fts_phrase(&q), q, limit as i64], |r| {
            row_hit(r, &r.get::<_, String>(4)?)
        })?;
        for hit in rows {
            let h = hit?;
            seen.insert(h.path.clone());
            hits.push(h);
        }
    }
    if matches!(mode, Mode::Text | Mode::All) && hits.len() < limit {
        let sql_long = "SELECT i.path,i.display,i.kind,i.availability,d.body FROM content_fts JOIN item i ON i.id=content_fts.rowid JOIN document d ON d.id=i.id WHERE content_fts MATCH ?1 AND ?2 IS NOT NULL ORDER BY rank,i.path LIMIT ?3";
        let sql_short = "SELECT i.path,i.display,i.kind,i.availability,d.body FROM document d JOIN item i ON i.id=d.id WHERE ?1 IS NOT NULL AND instr(d.normalized,?2)>0 ORDER BY i.path LIMIT ?3";
        let mut stmt = conn.prepare_cached(if q.chars().count() >= 3 {
            sql_long
        } else {
            sql_short
        })?;
        let rows = stmt.query_map(params![fts_phrase(&q), q, limit as i64], |r| {
            let mut h = row_hit(r, "text")?;
            let text: String = r.get(4)?;
            h.snippet = Some(short_snippet(&text, &q));
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
            for hit in semantic(conn, query, limit, model)? {
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
    Ok(hits)
}

pub fn status(conn: &Connection) -> Result<serde_json::Value> {
    let text: String =
        conn.query_row("SELECT value FROM info WHERE key='scan'", [], |r| r.get(0))?;
    let mut data: serde_json::Value = serde_json::from_str(&text)?;
    data["embeddings"] = conn
        .query_row("SELECT count(*) FROM embedding", [], |r| r.get::<_, i64>(0))?
        .into();
    Ok(data)
}

#[derive(Clone, Debug)]
pub struct Model {
    pub executable: PathBuf,
    pub language: String,
}

impl Model {
    fn signature(&self) -> Result<String> {
        let p = fs::canonicalize(&self.executable)?;
        let m = fs::metadata(&p)?;
        Ok(format!(
            "{}:{}:{:?}:{}",
            p.display(),
            m.len(),
            m.modified()?,
            self.language
        ))
    }
    fn encode(&self, text: &str) -> Result<Vec<f32>> {
        let mut p = Command::new(&self.executable)
            .arg(&self.language)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .context("launch local semantic model")?;
        p.stdin
            .take()
            .context("local model stdin")?
            .write_all(text.as_bytes())?;
        let output = p.wait_with_output()?;
        if !output.status.success() {
            bail!(
                "local semantic model unavailable: {}",
                String::from_utf8_lossy(&output.stderr).trim()
            );
        }
        let mut v: Vec<f32> = serde_json::from_slice(&output.stdout)?;
        if v.len() < 8 || v.len() > 4096 || v.iter().any(|x| !x.is_finite()) {
            bail!("invalid local model vector");
        }
        let len = v.iter().map(|x| x * x).sum::<f32>().sqrt();
        if !len.is_finite() || len <= f32::EPSILON {
            bail!("invalid local model norm");
        }
        for x in &mut v {
            *x /= len;
        }
        Ok(v)
    }
}

pub fn embed(database: &Path, model: &Model, max: usize) -> Result<usize> {
    let mut conn = open_write(&absolute(database)?)?;
    let model_id = model.signature()?;
    let tx = conn.transaction()?;
    let prior = tx
        .query_row("SELECT value FROM info WHERE key='model'", [], |r| {
            r.get::<_, String>(0)
        })
        .ok();
    if prior.as_deref() != Some(&model_id) {
        tx.execute("DELETE FROM embedding", [])?;
        tx.execute("INSERT INTO info(key,value) VALUES('model',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",[model_id])?;
    }
    let mut processed = 0;
    {
        let mut q=tx.prepare("SELECT d.id, substr(d.body,1,1400) FROM document d WHERE NOT EXISTS(SELECT 1 FROM embedding e WHERE e.id=d.id) ORDER BY d.id LIMIT ?")?;
        let mut rows = q.query([max.clamp(1, 1000) as i64])?;
        while let Some(r) = rows.next()? {
            let id: i64 = r.get(0)?;
            let text: String = r.get(1)?;
            let vector = model.encode(&text)?;
            let bytes = vector
                .into_iter()
                .flat_map(f32::to_le_bytes)
                .collect::<Vec<_>>();
            tx.execute(
                "INSERT INTO embedding(id,vector) VALUES(?,?)",
                params![id, bytes],
            )?;
            processed += 1;
        }
    }
    tx.commit()?;
    Ok(processed)
}

fn semantic(conn: &Connection, query: &str, limit: usize, model: &Model) -> Result<Vec<Hit>> {
    let current = model.signature()?;
    let stored = conn
        .query_row("SELECT value FROM info WHERE key='model'", [], |r| {
            r.get::<_, String>(0)
        })
        .context("no embeddings: run lumen embed first")?;
    if current != stored {
        bail!("model or language changed: build embeddings first");
    }
    let query = model.encode(query)?;
    let mut st=conn.prepare_cached("SELECT i.path,i.display,i.kind,i.availability,substr(d.body,1,160),e.vector FROM embedding e JOIN item i ON i.id=e.id JOIN document d ON d.id=e.id")?;
    let mut rows = st.query([])?;
    let mut hits = Vec::new();
    while let Some(r) = rows.next()? {
        let b: Vec<u8> = r.get(5)?;
        if b.len() != query.len() * 4 {
            bail!("stored and query embedding dimensions differ");
        }
        let sim = b
            .chunks_exact(4)
            .zip(&query)
            .map(|(x, q)| f32::from_le_bytes(x.try_into().unwrap()) * q)
            .sum::<f32>();
        if sim.is_finite() && sim > 0.25 {
            let mut hit = row_hit(r, "semantic")?;
            hit.snippet = r.get(4)?;
            hit.score = Some(sim.into());
            hits.push(hit);
        }
    }
    hits.sort_by(|a, b| {
        b.score
            .unwrap()
            .total_cmp(&a.score.unwrap())
            .then_with(|| a.path.cmp(&b.path))
    });
    hits.truncate(limit);
    Ok(hits)
}
