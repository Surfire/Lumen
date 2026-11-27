//! Independent local index. The CLI and native launcher share this implementation.
mod content;
mod diagnose;
mod docx;
mod external;
mod ffi;
mod gemma;
mod image_decode;
mod image_search;
mod index;
mod model;
mod name_fast;
mod pinyin;
mod platform;
mod progress;
mod query;
mod semantic;
mod vector;
mod watch;

pub use content::{
    ContentBatch, apply_content_scope, apply_content_scope_with_filter,
    apply_content_scope_with_image_ocr, index_content, preview_content_scope,
};
pub use diagnose::verify_cached_access;
pub use diagnose::{Diagnosis, Reason as DiagnoseReason, diagnose, validate_hit};
pub use external::{VolumeStatus, forget_volume, index_volume, volumes};
pub use gemma::{GemmaModel, ID as GEMMA_MODEL_ID};
pub use image_search::{
    ImageSearchSession, MODEL_ID as IMAGE_MODEL_ID, image_batch, image_scope, image_status,
};
pub use index::{scan, scan_with_progress};
pub use model::{Model, ModelBackend};
pub(crate) use name_fast::bucket_generation;
pub use progress::{ScanPhase, ScanProgress, ScanProgressReporter};
pub use query::allows_semantic as query_allows_semantic;
pub use semantic::{
    EmbedBatch, GemmaCoverage, GemmaSearchSession, embed, embed_batch, embed_with_backend,
    gemma_coverage,
};
pub use watch::{WatchEvent, watch, watch_with_launch_progress, watch_with_progress};

use anyhow::{Context, Result, bail};
use rusqlite::{Connection, OpenFlags, OptionalExtension, TransactionBehavior, params};
use serde::{Deserialize, Serialize};
use std::{
    fs,
    os::unix::fs::PermissionsExt,
    path::{Path, PathBuf},
    time::Duration,
};
use unicode_normalization::UnicodeNormalization;

pub const MAX_DOCUMENT: u64 = 2 * 1024 * 1024;
const SCHEMA_VERSION: i64 = 4;
const LEGACY_SCHEMA_VERSIONS: std::ops::RangeInclusive<i64> = 1..=3;
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
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub content_roots: Option<Vec<PathBuf>>,
    pub pdf_helper: Option<PathBuf>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pdf_helper_policy: Option<PdfHelperPolicy>,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub image_ocr: bool,
    // Keep existing Scope literals source-compatible without accepting a helper path.
    #[doc(hidden)]
    #[serde(skip)]
    pub image_ocr_helper: Option<std::convert::Infallible>,
    /// Which files below `content_roots` have their content (text, images)
    /// indexed. Filename search is never affected.
    #[serde(default, skip_serializing_if = "ContentFilter::is_default")]
    pub content_filter: ContentFilter,
}

/// Content-only selection rules. Every field is optional in JSON.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct ContentFilter {
    pub enable_pdf: bool,
    pub enable_docx: bool,
    pub enable_text: bool,
    pub enable_images: bool,
    pub enable_code: bool,
    pub allow_extensions: Vec<String>,
    pub deny_extensions: Vec<String>,
    /// Absolute folder paths (prefix match) or bare folder names (matched
    /// case-insensitively against any directory below a content root).
    pub deny_folders: Vec<String>,
}

impl Default for ContentFilter {
    fn default() -> Self {
        Self {
            enable_pdf: true,
            enable_docx: true,
            enable_text: true,
            enable_images: true,
            enable_code: false,
            allow_extensions: Vec::new(),
            deny_extensions: Vec::new(),
            deny_folders: Vec::new(),
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum ContentCategory {
    Pdf,
    Docx,
    Text,
    Image,
    Code,
}

/// Generated, dependency, cache and build output directories. Their files keep
/// their names in the filename index but their content is never extracted.
const CONTENT_NOISE_DIRS: &[&str] = &[
    "node_modules",
    "dist",
    "build",
    "out",
    ".next",
    ".nuxt",
    "coverage",
    "vendor",
    "site-packages",
    "__pycache__",
    ".venv",
    "venv",
    // Build `target` dirs are already dropped from names by the marker-checked
    // development_noise; a user folder named "Target" keeps its content.
    "logs",
    "tmp",
    "temp",
    ".cache",
    "pods",
    "deriveddata",
    "paddleocr",
    "ocr_output",
    "cmakefiles",
    "bower_components",
    "wandb",
    "checkpoints",
];
const CONTENT_NOISE_NAMES: &[&str] = &[
    "package-lock.json",
    "yarn.lock",
    "pnpm-lock.yaml",
    "cargo.lock",
    "poetry.lock",
];
const CONTENT_NOISE_SUFFIXES: &[&str] = &[
    ".lock",
    ".min.js",
    ".min.css",
    ".map",
    ".ocr.txt",
    ".dom.txt",
    ".transcript.md",
    ".summary.md",
    ".response.md",
];
pub(crate) const PROSE_EXTENSIONS: &[&str] = &["txt", "md", "markdown", "log", "csv", "tsv"];
pub(crate) const CODE_EXTENSIONS: &[&str] = &[
    "rs", "swift", "ts", "tsx", "js", "jsx", "py", "go", "java", "c", "cpp", "h", "hpp", "m", "mm",
    "rb", "php", "kt", "lua", "dart", "vue", "svelte", "sh", "zsh", "bash", "sql", "json", "yaml",
    "yml", "toml", "xml", "html", "htm", "css", "scss",
];

fn listed(list: &[String], extension: &str) -> bool {
    list.iter().any(|item| {
        item.trim()
            .trim_start_matches('.')
            .eq_ignore_ascii_case(extension)
    })
}

pub(crate) fn content_noise_dir(name: &str) -> bool {
    CONTENT_NOISE_DIRS
        .iter()
        .any(|noise| name.eq_ignore_ascii_case(noise))
}

impl ContentFilter {
    pub fn is_default(&self) -> bool {
        *self == Self::default()
    }

    /// The category this filter enables for `path`, from its name alone.
    pub(crate) fn category(&self, path: &Path) -> Option<ContentCategory> {
        let extension = path.extension()?.to_str()?.to_ascii_lowercase();
        let category = match extension.as_str() {
            "pdf" => ContentCategory::Pdf,
            "docx" => ContentCategory::Docx,
            ext if PROSE_EXTENSIONS.contains(&ext) => ContentCategory::Text,
            ext if CODE_EXTENSIONS.contains(&ext) => ContentCategory::Code,
            _ if image_decode::supported_path(path) => ContentCategory::Image,
            _ => return None,
        };
        if listed(&self.allow_extensions, &extension) {
            return Some(category);
        }
        match category {
            ContentCategory::Pdf => self.enable_pdf,
            ContentCategory::Docx => self.enable_docx,
            ContentCategory::Text => self.enable_text,
            ContentCategory::Image => self.enable_images,
            ContentCategory::Code => self.enable_code,
        }
        .then_some(category)
    }

    /// Noise folders/files and explicit denials, judged below the deepest
    /// matching root so a content root may itself live under e.g. `tmp`.
    /// Pure path inspection: never touches the filesystem.
    pub(crate) fn excludes(&self, path: &Path, roots: &[PathBuf]) -> bool {
        let Some(name) = path.file_name().and_then(|name| name.to_str()) else {
            return true;
        };
        let lower = name.to_ascii_lowercase();
        if CONTENT_NOISE_NAMES.contains(&lower.as_str())
            || CONTENT_NOISE_SUFFIXES
                .iter()
                .any(|suffix| lower.ends_with(suffix))
        {
            return true;
        }
        if let Some(extension) = path.extension().and_then(|ext| ext.to_str())
            && listed(&self.deny_extensions, extension)
        {
            return true;
        }
        let relative = roots
            .iter()
            .filter(|root| path.starts_with(root))
            .max_by_key(|root| root.as_os_str().len())
            .and_then(|root| path.strip_prefix(root).ok())
            .unwrap_or(path);
        let folders: Vec<&str> = relative
            .parent()
            .into_iter()
            .flat_map(Path::components)
            .filter_map(|part| part.as_os_str().to_str())
            .collect();
        folders.iter().any(|folder| content_noise_dir(folder))
            || self.deny_folders.iter().any(|denied| {
                let denied = denied.trim().trim_end_matches('/');
                if denied.is_empty() {
                    false
                } else if denied.starts_with('/') {
                    path.starts_with(denied)
                } else {
                    folders
                        .iter()
                        .any(|folder| folder.eq_ignore_ascii_case(denied))
                }
            })
    }
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
            && self.content_roots.is_none()
            && !self.documents
            && self.pdf_helper.is_none()
            && !self.image_ocr
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
            || development_noise(path, &self.roots)
            || (system_path(path)
                && !self.roots.iter().any(|root| {
                    path.starts_with(root) && (system_path(root) || scope_ancestor(root))
                }))
            || (path.starts_with("/Volumes")
                && !self
                    .roots
                    .iter()
                    .any(|root| root.starts_with("/Volumes") && path.starts_with(root)))
    }
}

fn home_library_tail(path: &Path) -> Option<&Path> {
    static HOME_LIBRARY: std::sync::OnceLock<Option<PathBuf>> = std::sync::OnceLock::new();
    let library = HOME_LIBRARY.get_or_init(|| {
        let home = absolute(Path::new(&std::env::var_os("HOME")?)).ok()?;
        Some(home.join("Library"))
    });
    if let Some(library) = library
        && let Ok(tail) = path.strip_prefix(library)
    {
        return Some(tail);
    }
    let mut parts = path.strip_prefix("/Users").ok()?.components();
    parts.next()?;
    (parts.next()?.as_os_str() == "Library").then_some(parts.as_path())
}

// These directories must be traversable to reach the allowed subtrees, but
// the traversal ancestors themselves are not searchable scope entries.
fn scope_ancestor(path: &Path) -> bool {
    path == Path::new("/System")
        || home_library_tail(path).is_some_and(|p| p.as_os_str().is_empty())
}

fn system_path(path: &Path) -> bool {
    (path.starts_with("/System")
        && path != Path::new("/System")
        && !path.starts_with("/System/Applications"))
        || home_library_tail(path).is_some_and(|tail| {
            !tail.as_os_str().is_empty()
                && !tail.starts_with("Mobile Documents")
                && !tail.starts_with("CloudStorage")
        })
        || [
            "/Library",
            "/usr",
            "/bin",
            "/sbin",
            "/opt",
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

fn is_build_target_dir(parent: &Path, target_dir: &Path) -> bool {
    ["Cargo.toml", "pom.xml", "build.sbt"]
        .iter()
        .any(|marker| fs::symlink_metadata(parent.join(marker)).is_ok())
        || fs::symlink_metadata(target_dir.join("CACHEDIR.TAG")).is_ok()
}

fn development_noise(path: &Path, roots: &[PathBuf]) -> bool {
    let (base, relative) = roots
        .iter()
        .filter_map(|root| {
            path.strip_prefix(root)
                .ok()
                .map(|tail| (Some(root.as_path()), tail))
        })
        .max_by_key(|(root, _)| root.map_or(0, |r| r.as_os_str().len()))
        .unwrap_or((None, path));
    for (depth, part) in relative.components().enumerate() {
        if let Some(name) = part.as_os_str().to_str() {
            // Hidden directories (including .venv, .gradle, .cargo, etc.)
            // are already excluded by sensitive_path.
            if [
                "node_modules",
                "DerivedData",
                "venv",
                "__pycache__",
                "Pods",
                "bower_components",
                "CMakeFiles",
            ]
            .iter()
            .any(|noise| name.eq_ignore_ascii_case(noise))
            {
                return true;
            }
            if name.eq_ignore_ascii_case("target") {
                let mut parent = base.map(Path::to_path_buf).unwrap_or_default();
                for prefix in relative.components().take(depth) {
                    parent.push(prefix.as_os_str());
                }
                let target_dir = parent.join(part.as_os_str());
                if is_build_target_dir(&parent, &target_dir) {
                    return true;
                }
            }
        }
    }
    false
}

fn library_sensitive_tail(path: &Path) -> Option<&Path> {
    if let Some(tail) = home_library_tail(path) {
        if !tail.as_os_str().is_empty()
            && !tail.starts_with("Mobile Documents")
            && !tail.starts_with("CloudStorage")
        {
            return Some(tail);
        }
        return None;
    }
    path.strip_prefix("/Library")
        .or_else(|_| path.strip_prefix("/System/Library"))
        .ok()
}

pub(crate) fn sensitive_path(path: &Path) -> bool {
    if path.components().any(|part| {
        part.as_os_str()
            .to_str()
            .is_some_and(|p| p.starts_with('.'))
    }) {
        return true;
    }
    library_sensitive_tail(path).is_some_and(|tail| {
        tail.components().any(|part| {
            part.as_os_str().to_str().is_some_and(|p| {
                ["keychains", "cookies", "caches"]
                    .iter()
                    .any(|name| p.eq_ignore_ascii_case(name))
            })
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
    let mut conn = Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_WRITE)?;
    conn.busy_timeout(Duration::from_secs(5))?;
    // Unlike journal_mode, synchronous is a per-connection setting.
    conn.pragma_update(None, "synchronous", "NORMAL")?;
    conn.pragma_update(None, "wal_autocheckpoint", 1000)?;
    conn.pragma_update(None, "journal_size_limit", 67_108_864)?;
    conn.pragma_update(None, "cache_size", -16_000)?;
    match catalog_schema(&conn)? {
        (DATABASE_APPLICATION_ID, SCHEMA_VERSION) => {
            if !name_fast::has_generation_buckets(&conn)? {
                let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
                if !name_fast::has_generation_buckets(&tx)? {
                    name_fast::install_generation(&tx)?;
                    tx.commit()?;
                }
            }
        }
        (DATABASE_APPLICATION_ID, version) if LEGACY_SCHEMA_VERSIONS.contains(&version) => {
            migrate_catalog(&mut conn)?;
        }
        (0, 0) if metadata.len() == 0 => {
            conn.pragma_update(None, "journal_mode", "WAL")?;
            migrate_catalog(&mut conn)?;
        }
        _ => bail!("not a supported Lumen index; no changes made"),
    }
    image_search::migrate_legacy_scope(&mut conn)?;
    Ok((conn, lease))
}

fn catalog_schema(conn: &Connection) -> rusqlite::Result<(i64, i64)> {
    conn.query_row(
        "SELECT application_id,user_version FROM pragma_application_id,pragma_user_version",
        [],
        |row| Ok((row.get(0)?, row.get(1)?)),
    )
}

fn migrate_catalog(conn: &mut Connection) -> Result<()> {
    let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
    // Another writer may have migrated while we were acquiring the lock.
    let uninitialized = match catalog_schema(&tx)? {
        (DATABASE_APPLICATION_ID, SCHEMA_VERSION) => return Ok(()),
        (DATABASE_APPLICATION_ID, version) if LEGACY_SCHEMA_VERSIONS.contains(&version) => false,
        (0, 0) => true,
        _ => bail!("not a supported Lumen index; no changes made"),
    };
    if uninitialized {
        tx.pragma_update(None, "application_id", DATABASE_APPLICATION_ID)?;
        tx.execute_batch(
            "CREATE TABLE IF NOT EXISTS item(
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
    ",
        )?;
    }
    tx.execute_batch(
        "CREATE TABLE IF NOT EXISTS document_state(id INTEGER PRIMARY KEY, stamp TEXT NOT NULL);",
    )?;
    if !semantic::installed(&tx)? {
        tx.execute_batch(semantic::SCHEMA)?;
    }
    tx.execute_batch(semantic::SKIP_SCHEMA)?;
    tx.execute_batch(semantic::VERSIONED_SCHEMA)?;
    tx.execute_batch(content::SCHEMA)?;
    if !name_fast::has_mtime(&tx)? {
        tx.execute_batch("ALTER TABLE item ADD COLUMN mtime INTEGER NOT NULL DEFAULT 0;")?;
    }
    name_fast::install_generation(&tx)?;
    if !uninitialized {
        // Retain the user's scope settings, but require a policy pass and a
        // fresh journal seed even if the serialized scope is unchanged.
        tx.execute(
            "DELETE FROM info WHERE key IN ('scope_policy_v3','watch_checkpoint_v1',
             'watch_replay_overlap_v1','watch_reconciled_at','walk_sample')",
            [],
        )?;
    }
    tx.pragma_update(None, "user_version", SCHEMA_VERSION)?;
    tx.commit()?;
    Ok(())
}

pub fn open_read(path: &Path) -> Result<Connection> {
    let path = absolute(path)?;
    if !fs::symlink_metadata(&path)?.is_file() {
        bail!("index is not a regular file");
    }
    let connection = Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY)?;
    connection.busy_timeout(Duration::from_secs(3))?;
    connection.pragma_update(None, "cache_size", -8_000)?;
    let (application, version) = catalog_schema(&connection)?;
    if application != DATABASE_APPLICATION_ID
        || (version != SCHEMA_VERSION && !LEGACY_SCHEMA_VERSIONS.contains(&version))
    {
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
    #[serde(default)]
    pub entries_visited: u64,
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
    #[serde(skip_serializing_if = "Option::is_none")]
    pub pdf_page: Option<u32>,
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
        pdf_page: None,
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
    Ok(stamp.and_then(|stamp| {
        // The index may append an extractor version or a helper signature.
        // Normalize both legacy 7-field and current 5-field rows to the
        // five filesystem metadata fields (dev:ino:size:mtime:mtime_nsec).
        index::stamp_prefix(&stamp).map(str::to_owned)
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
    let mut hits = search_with_names(conn, query, mode, limit, model, None)?;
    if let Some(database) = conn.path().filter(|path| !path.is_empty()) {
        external::append_hits(
            Path::new(database),
            query,
            mode,
            limit.clamp(1, 100),
            &mut hits,
        );
    }
    Ok(hits)
}

/// A persistent reader for the native launcher's request stream.
pub struct SearchSession {
    conn: Connection,
    names: Option<name_fast::NameFast>,
}

impl SearchSession {
    pub fn open(path: &Path) -> Result<Self> {
        Self::open_with_names(path, true)
    }

    pub fn open_with_names(path: &Path, enable_name_index: bool) -> Result<Self> {
        let path = absolute(path)?;
        let conn = open_read(&path)?;
        let names = enable_name_index.then(|| name_fast::NameFast::new(&path, &conn));
        Ok(Self { conn, names })
    }

    /// Check previously presented hits in order without reopening the main catalog.
    pub fn validate(&self, hits: &[diagnose::HitInput<'_>]) -> Vec<bool> {
        let Some(database) = self.conn.path().filter(|path| !path.is_empty()) else {
            return vec![false; hits.len()];
        };
        diagnose::validate_session_hits(&self.conn, Path::new(database), hits)
    }

    /// Report scan coverage and embedding counts from one consistent catalog snapshot.
    pub fn status(&self, include_scope: bool) -> Result<serde_json::Value> {
        diagnose::read_snapshot(&self.conn, |snapshot| {
            status_with_scope(snapshot, include_scope)
        })
    }

    /// Return a paragraph-aligned window around a matched snippet or query in a scoped document.
    pub fn excerpt(
        &self,
        path: &str,
        query: Option<&str>,
        snippet: Option<&str>,
        max_chars: usize,
    ) -> Result<Option<String>> {
        let path = path.trim();
        if path.is_empty() {
            return Ok(None);
        }
        diagnose::read_snapshot(&self.conn, |snapshot| {
            let candidate = Path::new(path);
            if external::is_external(candidate) {
                return Ok(None);
            }
            let Some(scope) = saved_index_scope(snapshot)? else {
                return Ok(None);
            };
            if !scope.documents
                || !scope.roots.iter().any(|root| candidate.starts_with(root))
                || !scope.allows(candidate)
                || (scope.content_roots.is_some()
                    && !index::in_explicit_content_root(&scope, candidate))
            {
                return Ok(None);
            }
            let body: Option<String> = snapshot
                .prepare_cached(
                    "SELECT d.body FROM item i JOIN document d ON d.id=i.id
                     WHERE i.path=?1 AND i.availability IN ('local','provider_metadata_only')",
                )?
                .query_row([path], |row| row.get(0))
                .optional()?;
            Ok(body
                .as_deref()
                .and_then(|text| excerpt_window(text, query, snippet, max_chars)))
        })
    }

    pub fn search(&mut self, query: &str, mode: Mode, limit: usize) -> Result<Vec<Hit>> {
        let mut hits =
            search_with_names(&self.conn, query, mode, limit, None, self.names.as_mut())?;
        if let Some(database) = self.conn.path().filter(|path| !path.is_empty()) {
            external::append_hits(
                Path::new(database),
                query,
                mode,
                limit.clamp(1, 100),
                &mut hits,
            );
        }
        Ok(hits)
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
    let terms = query::Terms::parse(&q);
    let cached = if matches!(mode, Mode::Name | Mode::All) {
        match names {
            Some(names) => names.search(conn, &q, terms.as_ref(), limit)?,
            None => None,
        }
    } else {
        None
    };
    if let Some(terms) = terms {
        let (generation, cached_names) =
            cached.map_or((None, None), |(v, hits)| (Some(v), Some(hits)));
        let mut hits = if mode == Mode::Name && cached_names.is_some() {
            cached_names.unwrap_or_default()
        } else if mode != Mode::Semantic {
            query::search(conn, &terms, mode, limit, cached_names)?
        } else {
            Vec::new()
        };
        if terms.permits_semantic() {
            append_semantic_hits(conn, query, mode, limit, model, &mut hits)?;
        }
        if generation.is_some() && generation != name_fast::name_generation(conn)? {
            return search_with_names(conn, query, mode, limit, model, None);
        }
        return Ok(hits);
    }
    let (version, mut hits) = cached.map_or((None, Vec::new()), |(v, hits)| (Some(v), hits));
    if version.is_none() && matches!(mode, Mode::Name | Mode::All) {
        hits = name_fast::search_disk(conn, &q, limit)?;
    }
    let mut seen = std::collections::HashSet::new();
    if mode == Mode::All && hits.len() < limit {
        seen.extend(hits.iter().map(|hit| hit.path.clone()));
    }
    if matches!(mode, Mode::Text | Mode::All) && hits.len() < limit
        // The short-text query can drive the join in item path order. An
        // empty document table should not lead to a catalog-wide pass.
        && (q.chars().count() >= 3 || conn.prepare_cached(
            "SELECT EXISTS(SELECT 1 FROM document)"
        )?.query_row([], |row| row.get::<_, bool>(0))?)
    {
        let (stamp, state_join) = document_stamp_sql(conn)?;
        let sql = if q.chars().count() >= 3 {
            format!("SELECT i.path,i.display,i.kind,i.availability,d.body,{stamp} AS document_stamp,d.id
                     FROM content_fts JOIN item i ON i.id=content_fts.rowid JOIN document d ON d.id=i.id
                     {state_join} WHERE content_fts MATCH ?1 AND ?2 IS NOT NULL
                     AND i.availability<>'unverified' ORDER BY rank,i.path LIMIT ?3")
        } else {
            format!(
                // Start at documents instead of scanning all items for ORDER BY i.path.
                "SELECT i.path,i.display,i.kind,i.availability,d.body,{stamp} AS document_stamp,d.id
                     FROM document d CROSS JOIN item i ON i.id=d.id
                     {state_join} WHERE ?1 IS NOT NULL AND instr(d.normalized,?2)>0
                     AND i.availability<>'unverified' ORDER BY i.path LIMIT ?3"
            )
        };
        let mut stmt = conn.prepare_cached(&sql)?;
        let rows = stmt.query_map(params![fts_phrase(&q), q, limit as i64], |r| {
            let mut h = row_hit(r, "text")?;
            let text: String = r.get(4)?;
            h.document_stamp = read_document_stamp(r)?;
            // Attach the page only for a stamped PDF and a same-page match.
            let page = if h.document_stamp.is_some()
                && index::DocumentKind::for_path(Path::new(&h.path))
                    == Some(index::DocumentKind::Pdf)
            {
                content::matching_page(conn, r.get(6)?, &text, &[&q])?
            } else {
                None
            };
            h.pdf_page = page.map(|(number, _)| number);
            h.snippet = Some(short_snippet(page.map_or(&text, |(_, page)| page), &q));
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
    append_semantic_hits(conn, query, mode, limit, model, &mut hits)?;
    if let Some(version) = version {
        // A concurrent item change may obsolete in-memory name hits while
        // computing names or combining them with text. Read the current view.
        if Some(version) != name_fast::name_generation(conn)? {
            return search_with_names(conn, query, mode, limit, model, None);
        }
    }
    Ok(hits)
}

fn append_semantic_hits(
    conn: &Connection,
    query: &str,
    mode: Mode,
    limit: usize,
    model: Option<ModelBackend<'_>>,
    hits: &mut Vec<Hit>,
) -> Result<()> {
    if !matches!(mode, Mode::Semantic | Mode::All) || hits.len() >= limit {
        return Ok(());
    }
    if let Some(model) = model {
        let mut seen: std::collections::HashSet<_> =
            hits.iter().map(|hit| hit.path.clone()).collect();
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
    Ok(())
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
    data["content"] = serde_json::to_value(content::coverage(conn)?)?;
    data["content"]["image_ocr"] = saved_index_scope(conn)?
        .is_some_and(|scope| scope.image_ocr)
        .into();
    semantic::add_status(conn, &mut data)?;
    data["unverified"] = unverified.into();
    Ok(data)
}

pub fn status_with_scope(conn: &Connection, include_scope: bool) -> Result<serde_json::Value> {
    let mut report = status(conn)?;
    if include_scope && let Some(scope) = saved_index_scope(conn)? {
        report["scope"] = serde_json::json!({
            "roots": scope.roots,
            "allow": scope.allow,
            "deny": scope.deny,
            "documents": scope.documents,
            "content_roots": scope.content_roots,
            "content_filter": scope.content_filter,
        });
    }
    Ok(report)
}

fn find_excerpt_anchor(text: &str, needle: &str) -> Option<usize> {
    if let Some(pos) = text.find(needle) {
        return Some(pos);
    }
    let trimmed = needle.trim();
    if trimmed.is_empty() {
        return None;
    }
    let query_norm = norm(trimmed);
    let q_chars: Vec<char> = query_norm.chars().collect();
    if q_chars.is_empty() {
        return None;
    }
    // Bound normalization scan over a single indexed document while preserving UTF-8 byte offsets.
    let indexed: Vec<(usize, char)> = text
        .char_indices()
        .take(262_144)
        .flat_map(|(byte, ch)| ch.to_lowercase().map(move |lower| (byte, lower)))
        .collect();
    indexed
        .windows(q_chars.len())
        .find(|win| win.iter().zip(&q_chars).all(|((_, a), b)| a == b))
        .map(|win| win[0].0)
}

fn excerpt_window(
    text: &str,
    query: Option<&str>,
    snippet: Option<&str>,
    max_chars: usize,
) -> Option<String> {
    let trimmed = text.trim();
    if trimmed.is_empty() {
        return None;
    }
    let budget = max_chars.clamp(400, 3200);
    if trimmed.chars().count() <= budget {
        return Some(trimmed.to_owned());
    }

    let clean_snippet = snippet
        .map(|s| s.trim_matches(|c: char| c.is_whitespace() || c == '…' || c == '.'))
        .filter(|s| !s.is_empty());
    let anchor = clean_snippet
        .and_then(|s| {
            text.find(s).or_else(|| {
                let prefix: String = s.chars().take(48).collect();
                (prefix.chars().count() >= 6)
                    .then(|| text.find(&prefix))
                    .flatten()
            })
        })
        .or_else(|| {
            query
                .map(str::trim)
                .filter(|q| !q.is_empty())
                .and_then(|q| {
                    find_excerpt_anchor(text, q).or_else(|| {
                        q.split_whitespace()
                            .find(|w| w.chars().count() >= 2)
                            .and_then(|w| find_excerpt_anchor(text, w))
                    })
                })
        })
        .unwrap_or(0);

    let before_target = budget / 3;
    let mut start = text[..anchor]
        .char_indices()
        .rev()
        .nth(before_target.saturating_sub(1))
        .map_or(0, |(idx, _)| idx);
    let mut chars_before = text[start..anchor].chars().count();
    if start > 0
        && let Some(rel) = text[start..anchor]
            .char_indices()
            .take(160)
            .find_map(|(i, c)| (c == '\n').then_some(i))
    {
        let snapped = start + rel + 1;
        if snapped <= anchor {
            start = snapped;
            chars_before = text[start..anchor].chars().count();
        }
    }

    let after_budget = budget.saturating_sub(chars_before);
    let mut end = text[anchor..]
        .char_indices()
        .nth(after_budget)
        .map_or(text.len(), |(idx, _)| anchor + idx);
    if end < text.len()
        && let Some(rel) = text[anchor..end]
            .char_indices()
            .rev()
            .take(160)
            .find_map(|(i, c)| (c == '\n').then_some(i))
    {
        let anchor_min = anchor + text[anchor..].char_indices().nth(64).map_or(0, |(i, _)| i);
        if anchor + rel > anchor_min {
            end = anchor + rel;
        }
    }

    let window = text[start..end].trim();
    if window.is_empty() {
        return None;
    }
    let mut out = String::new();
    if start > 0 && !text[..start].trim().is_empty() {
        out.push_str("…\n");
    }
    out.push_str(window);
    if end < text.len() && !text[end..].trim().is_empty() {
        out.push_str("\n…");
    }
    Some(out)
}

#[cfg(test)]
mod scope_tests {
    use super::*;

    #[test]
    fn scope_json_without_a_content_filter_keeps_defaults_and_round_trips_unchanged() {
        let legacy = r#"{"roots":["/Users/a"],"allow":[],"deny":[],"documents":true,"content_roots":["/Users/a/Docs"],"pdf_helper":null}"#;
        let scope: Scope = serde_json::from_str(legacy).unwrap();
        assert_eq!(scope.content_filter, ContentFilter::default());
        assert_eq!(serde_json::to_string(&scope).unwrap(), legacy);
        let partial: ContentFilter = serde_json::from_str(r#"{"enable_code":true}"#).unwrap();
        assert!(partial.enable_code && partial.enable_pdf && partial.enable_images);
        let roots = [PathBuf::from("/Users/a/tmp/Docs")];
        let filter = ContentFilter::default();
        // Noise is judged below the content root, which may itself sit under `tmp`.
        assert!(!filter.excludes(Path::new("/Users/a/tmp/Docs/x.md"), &roots));
        assert!(filter.excludes(Path::new("/Users/a/tmp/Docs/Build/x.md"), &roots));
        assert!(filter.excludes(Path::new("/Users/a/tmp/Docs/package-lock.json"), &roots));
        assert_eq!(
            filter.category(Path::new("/d/a.TXT")),
            Some(ContentCategory::Text)
        );
        assert_eq!(filter.category(Path::new("/d/a.swift")), None);
        assert_eq!(filter.category(Path::new("/d/a.bin")), None);
    }

    #[test]
    fn system_and_user_library_noise_leave_app_and_cloud_paths_traversable() {
        let scope = Scope::default();
        for path in [
            "/Library/Installer.db",
            "/usr/share/files",
            "/bin/etc",
            "/sbin/etc",
            "/opt/bin",
            "/System/Library/PrefPane",
            "/Users/example/Library/Application Support/program/file",
        ] {
            assert!(
                !scope.allows(Path::new(path)),
                "unexpected scoped path {path}"
            );
        }
        for path in [
            "/System",
            "/System/Applications/Preview.app",
            "/Applications/Lumen.app",
            "/Users/example/Library",
            "/Users/example/Library/CloudStorage/OneDrive/a.txt",
            "/Users/example/Library/Mobile Documents/com~apple~CloudDocs/a.txt",
        ] {
            assert!(scope.allows(Path::new(path)), "excluded {path}");
        }
        for path in ["/System", "/Users/example/Library"] {
            assert!(scope_ancestor(Path::new(path)));
        }
    }

    #[test]
    fn user_target_cookies_and_caches_are_allowed_while_build_and_library_paths_are_excluded() {
        let root = fs::canonicalize(std::env::temp_dir())
            .unwrap()
            .join(format!("lumen-scope-narrow-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        let user_target = root.join("Documents/Q4/Target");
        let user_cookies = root.join("Documents/Recipes/Cookies");
        let user_caches = root.join("Documents/Caches");
        let cargo_proj = root.join("Projects/crate");
        let maven_proj = root.join("Projects/maven");
        for dir in [
            &user_target,
            &user_cookies,
            &user_caches,
            &cargo_proj.join("target"),
            &maven_proj.join("target"),
        ] {
            fs::create_dir_all(dir).unwrap();
        }
        fs::write(cargo_proj.join("Cargo.toml"), "[package]\nname=\"x\"\n").unwrap();
        fs::write(maven_proj.join("pom.xml"), "<project/>").unwrap();

        let scope = Scope {
            roots: vec![root.clone()],
            ..Scope::default()
        };
        assert!(scope.allows(&user_target.join("plan.md")));
        assert!(scope.allows(&user_cookies.join("chocolate.md")));
        assert!(scope.allows(&user_caches.join("notes.md")));
        assert!(!scope.allows(&cargo_proj.join("target/debug/bin")));
        assert!(!scope.allows(&maven_proj.join("target/classes/App.class")));

        let default_scope = Scope::default();
        assert!(default_scope.allows(Path::new(
            "/Users/example/Library/CloudStorage/OneDrive/Recipes/Cookies/oatmeal.md"
        )));
        for blocked in [
            "/Users/example/Library/Caches/com.apple.Safari/cache.db",
            "/Users/example/Library/Cookies/Cookies.binarycookies",
            "/Users/example/Library/Keychains/login.keychain-db",
            "/Library/Caches/system.cache",
            "/Users/example/Documents/.secret/file.txt",
        ] {
            assert!(
                !default_scope.allows(Path::new(blocked)),
                "allowed {blocked}"
            );
        }
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn short_text_query_scans_documents_instead_of_full_item_table() {
        let root = fs::canonicalize(std::env::temp_dir())
            .unwrap()
            .join(format!("lumen-short-text-plan-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(&root).unwrap();
        let db = root.join("index.sqlite");
        fs::write(root.join("alpha.txt"), "普通开头段落。").unwrap();
        fs::write(root.join("方案文档.txt"), "这是临床方案正文。").unwrap();
        crate::scan(
            &db,
            &Scope {
                roots: vec![root.clone()],
                documents: true,
                ..Scope::default()
            },
        )
        .unwrap();

        let conn = open_read(&db).unwrap();
        let (stamp, state_join) = document_stamp_sql(&conn).unwrap();
        let plan_sql = format!(
            "EXPLAIN QUERY PLAN
             SELECT i.path,i.display,i.kind,i.availability,d.body,{stamp} AS document_stamp,d.id
             FROM document d CROSS JOIN item i ON i.id=d.id
             {state_join} WHERE ?1 IS NOT NULL AND instr(d.normalized,?2)>0
             AND i.availability<>'unverified' ORDER BY i.path LIMIT ?3"
        );
        let plan: Vec<String> = conn
            .prepare(&plan_sql)
            .unwrap()
            .query_map(rusqlite::params!["方案", "方案", 24], |r| {
                r.get::<_, String>(3)
            })
            .unwrap()
            .collect::<std::result::Result<_, _>>()
            .unwrap();
        assert!(
            plan.iter().any(|step| step.contains("SCAN d")),
            "expected SCAN d, got {plan:?}"
        );
        assert!(
            !plan.iter().any(|step| step.contains("SCAN i")),
            "unexpected full item table scan: {plan:?}"
        );
        drop(conn);

        let mut session = SearchSession::open(&db).unwrap();
        let hits = session.search("方案", Mode::Text, 24).unwrap();
        assert_eq!(hits.len(), 1);
        assert_eq!(hits[0].name, "方案文档.txt");

        let large_prefix: String = (0..60)
            .map(|i| format!("前置章节内容段落第{i}行。\n"))
            .collect();
        let large_suffix: String = (0..60)
            .map(|i| format!("后续扩展章节第{i}行。\n"))
            .collect();
        let large_body = format!("{large_prefix}关键临床方案正文核心段落。\n{large_suffix}");
        let excerpt = excerpt_window(&large_body, Some("临床方案"), None, 1000).unwrap();
        assert!(excerpt.contains("关键临床方案正文核心段落"));
        assert!(excerpt.starts_with("…\n"));
        assert!(excerpt.ends_with("\n…"));
        assert!(excerpt.chars().count() <= 1010);

        fs::remove_dir_all(root).unwrap();
    }
}
