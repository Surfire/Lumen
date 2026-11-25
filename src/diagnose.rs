//! Single-path diagnostics. The selected file contributes metadata, never bytes.
use crate::{
    PdfHelperPolicy, Scope, absolute, document_stamp_sql,
    index::{DocumentKind, INDEX_SIDECARS, is_index_path},
    open_read, read_document_stamp, saved_index_scope, semantic, with_suffix,
};
use rusqlite::{Connection, OptionalExtension};
use serde::Serialize;
use std::path::{Component, Path, PathBuf};

#[cfg(target_os = "macos")]
use std::{
    collections::HashMap,
    ffi::CString,
    fs::{File, OpenOptions},
    io,
    mem::MaybeUninit,
    os::{
        fd::{AsRawFd, FromRawFd},
        unix::{
            ffi::OsStrExt,
            fs::{MetadataExt, OpenOptionsExt},
        },
    },
};

/// Guard the startup snapshot against out-of-band access changes, including
/// privacy-policy revocation which may not produce any filesystem event.
pub fn verify_cached_access(hits: &mut Vec<crate::Hit>) {
    #[cfg(not(target_os = "macos"))]
    hits.clear();
    #[cfg(target_os = "macos")]
    {
        let Ok(_io) = crate::platform::NoMaterialization::enter() else {
            hits.clear();
            return;
        };
        let mut directory_access = std::collections::HashMap::<PathBuf, bool>::new();
        hits.retain(|hit| {
            let path = Path::new(&hit.path);
            if !path.is_absolute() || path.components().any(|part| part == Component::ParentDir) {
                return false;
            }
            let directory = hit.kind == "directory";
            if !directory && hit.kind != "file" {
                return false;
            }
            let Some(parent) = path.parent() else {
                return false;
            };
            for ancestor in parent.ancestors().collect::<Vec<_>>().into_iter().rev() {
                if !*directory_access
                    .entry(ancestor.into())
                    .or_insert_with(|| crate::watch::can_enumerate(ancestor))
                {
                    return false;
                }
            }
            let Ok(live) = selected_metadata(path, directory) else {
                return false;
            };
            if live.path != path || live.availability != hit.availability {
                return false;
            }
            if directory
                && live.availability != "placeholder"
                && !*directory_access
                    .entry(path.into())
                    .or_insert_with(|| crate::watch::can_enumerate(path))
            {
                return false;
            }
            if hit.snippet.is_some() || hit.document_stamp.is_some() {
                return hit.document_stamp.is_some()
                    && hit.document_stamp == live.stamp
                    && crate::watch::can_read_document(path, hit.document_stamp.as_deref());
            }
            true
        });
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Reason {
    Indexed,
    NotIndexed,
    Stale,
    Unverified,
    IndexUnavailable,
    ScopeUnknown,
    Excluded,
    OutsideScope,
    Missing,
    Unreadable,
    Symlink,
    NotFile,
    CloudAncestor,
    CloudNameOnly,
    TextDisabled,
    OutsideContentScope,
    Unsupported,
    PdfHelperUnconfigured,
    PendingGemma,
    GemmaLimited,
    GemmaSkipped,
    Unknown,
}

#[derive(Serialize)]
pub struct Diagnosis {
    pub name: Reason,
    pub text: Reason,
    pub semantic: Reason,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub availability: Option<&'static str>,
}

impl Diagnosis {
    fn blocked(reason: Reason) -> Self {
        Self {
            name: reason,
            text: reason,
            semantic: reason,
            availability: None,
        }
    }
}

pub fn diagnose(database: &Path, path: &Path) -> Diagnosis {
    if !path.components().any(|c| c == Component::ParentDir)
        && let Ok(path) = absolute(path)
        && crate::external::is_external(&path)
    {
        return crate::external::diagnose(database, &path)
            .unwrap_or_else(|| Diagnosis::blocked(Reason::IndexUnavailable));
    }
    diagnose_catalog(database, path)
}

pub(super) fn diagnose_catalog(database: &Path, path: &Path) -> Diagnosis {
    #[cfg(target_os = "macos")]
    let Ok(_io) = crate::platform::NoMaterialization::enter() else {
        return Diagnosis::blocked(Reason::Unknown);
    };
    // A lexical '..' can refer somewhere else when its preceding component is
    // a symlink. Do not reinterpret such a path as the selected file.
    if path.as_os_str().is_empty() || path.components().any(|c| c == Component::ParentDir) {
        return Diagnosis::blocked(Reason::Unknown);
    }
    let Ok(path) = absolute(path) else {
        return Diagnosis::blocked(Reason::Unknown);
    };
    let Ok(database) = absolute(database) else {
        return Diagnosis::blocked(Reason::IndexUnavailable);
    };
    let Ok(conn) = open_read(&database) else {
        return Diagnosis::blocked(Reason::IndexUnavailable);
    };
    let Ok(snapshot) = conn.unchecked_transaction() else {
        return Diagnosis::blocked(Reason::IndexUnavailable);
    };
    inspect(&snapshot, &database, &path)
}

/// Check one previously presented hit against the committed catalog and the
/// current filesystem. The lookup uses the exact saved path and reads no bytes.
pub fn validate_hit(
    database: &Path,
    path: &Path,
    kind: &str,
    availability: &str,
    stamp: Option<&str>,
) -> bool {
    #[cfg(target_os = "macos")]
    let Ok(_io) = crate::platform::NoMaterialization::enter() else {
        return false;
    };
    if crate::external::is_external(path) {
        let Some(path) = path.to_str() else {
            return false;
        };
        let mut visible = [false];
        crate::external::validate_batch(
            database,
            &[(path, kind, availability, stamp)],
            &mut visible,
            &mut MetadataBatch::default(),
        );
        return visible[0];
    }
    validate_catalog_hit(database, path, kind, availability, stamp)
}

fn validate_catalog_hit(
    database: &Path,
    path: &Path,
    kind: &str,
    availability: &str,
    stamp: Option<&str>,
) -> bool {
    let result = (|| -> crate::Result<bool> {
        let database = absolute(database)?;
        let conn = open_read(&database)?;
        read_snapshot(&conn, |snapshot| {
            Ok(
                CatalogValidator::new(snapshot, &database).is_some_and(|validator| {
                    validator.check(
                        &mut MetadataBatch::default(),
                        path,
                        kind,
                        availability,
                        stamp,
                    )
                }),
            )
        })
    })();
    result.unwrap_or(false)
}

pub(super) type HitInput<'a> = (&'a str, &'a str, &'a str, Option<&'a str>);

/// Validate an ordered batch using the session's existing catalog connection.
/// The metadata checks never read the selected files' contents.
pub(super) fn validate_session_hits(
    conn: &Connection,
    database: &Path,
    hits: &[HitInput<'_>],
) -> Vec<bool> {
    let mut visible = vec![false; hits.len()];
    #[cfg(target_os = "macos")]
    let Ok(_io) = crate::platform::NoMaterialization::enter() else {
        return visible;
    };
    let mut paths = MetadataBatch::default();
    let _ = read_snapshot(conn, |snapshot| {
        if let Some(validator) = CatalogValidator::new(snapshot, database) {
            for (&(path, kind, availability, stamp), visible) in hits.iter().zip(&mut visible) {
                let path = Path::new(path);
                if !crate::external::is_external(path) {
                    *visible = validator.check(&mut paths, path, kind, availability, stamp);
                }
            }
        }
        Ok(())
    });
    crate::external::validate_batch(database, hits, &mut visible, &mut paths);
    visible
}

/// Use one WAL snapshot for the version check, scope rules, and hit reads.
/// A caller's transaction (including an already pinned snapshot) stays open.
pub(super) fn read_snapshot<T>(
    conn: &Connection,
    read: impl FnOnce(&Connection) -> crate::Result<T>,
) -> crate::Result<T> {
    let tx = conn
        .is_autocommit()
        .then(|| conn.unchecked_transaction())
        .transpose()?;
    let snapshot = tx.as_deref().unwrap_or(conn);
    // BEGIN is deferred: take a real read of main before any cache lookup so
    // PRAGMA data_version describes the WAL snapshot pinned by this SELECT.
    snapshot
        .prepare_cached("SELECT 1 FROM main.sqlite_schema LIMIT 1")?
        .exists([])?;
    read(snapshot)
}

#[cfg(test)]
pub(super) mod snapshot_tests {
    use rusqlite::{Connection, ffi};
    use std::{cell::RefCell, path::Path};

    thread_local! {
        static WRITER: RefCell<Option<Connection>> = const { RefCell::new(None) };
    }

    // Commit between statements of the actual search, without sleeps or a
    // search-side hook. SQLite calls this on the reader's thread, but the
    // writes use a separate connection to an unrelated table.
    pub fn start_benign_writes(reader: &Connection, database: &Path) {
        let writer = Connection::open(database).unwrap();
        writer
            .execute_batch(
                "CREATE TABLE benign_writes(n INTEGER); INSERT INTO benign_writes VALUES (0)",
            )
            .unwrap();
        WRITER.with_borrow_mut(|slot| assert!(slot.replace(writer).is_none()));
        unsafe {
            ffi::sqlite3_trace_v2(
                reader.handle(),
                ffi::SQLITE_TRACE_PROFILE,
                Some(after_read),
                std::ptr::null_mut(),
            );
        }
    }

    unsafe extern "C" fn after_read(
        _: std::ffi::c_uint,
        _: *mut std::ffi::c_void,
        stmt: *mut std::ffi::c_void,
        _: *mut std::ffi::c_void,
    ) -> std::ffi::c_int {
        // PROFILE provides a live statement on the registered reader. Only
        // interleave writes while that connection holds a read transaction.
        let db = unsafe { ffi::sqlite3_db_handle(stmt.cast()) };
        if unsafe { ffi::sqlite3_txn_state(db, c"main".as_ptr()) } == ffi::SQLITE_TXN_READ {
            WRITER.with_borrow(|writer| {
                if let Some(writer) = writer {
                    let _ = writer.execute("UPDATE benign_writes SET n=n+1", []);
                }
            });
        }
        0
    }

    pub fn stop_benign_writes(reader: &Connection) -> i64 {
        unsafe { ffi::sqlite3_trace_v2(reader.handle(), 0, None, std::ptr::null_mut()) };
        let writer = WRITER.with_borrow_mut(|slot| slot.take().unwrap());
        writer
            .query_row("SELECT n FROM benign_writes", [], |r| r.get(0))
            .unwrap()
    }
}

pub(super) struct CatalogValidator<'a> {
    conn: &'a Connection,
    scope: Scope,
    database: &'a Path,
    sidecars: [PathBuf; INDEX_SIDECARS.len()],
}

impl<'a> CatalogValidator<'a> {
    pub(super) fn new(conn: &'a Connection, database: &'a Path) -> Option<Self> {
        Some(Self {
            conn,
            scope: saved_index_scope(conn).ok()??,
            database,
            sidecars: INDEX_SIDECARS.map(|suffix| with_suffix(database, suffix)),
        })
    }

    pub(super) fn check(
        &self,
        paths: &mut MetadataBatch,
        path: &Path,
        kind: &str,
        availability: &str,
        stamp: Option<&str>,
    ) -> bool {
        self.check_row(paths, path, kind, availability, stamp)
            .unwrap_or(false)
    }

    fn check_row(
        &self,
        paths: &mut MetadataBatch,
        path: &Path,
        kind: &str,
        availability: &str,
        stamp: Option<&str>,
    ) -> crate::Result<bool> {
        let Self {
            conn,
            scope,
            database,
            sidecars,
        } = self;
        if !path.is_absolute()
            || path.components().any(|c| c == Component::ParentDir)
            || !matches!(kind, "file" | "directory")
            || !matches!(
                availability,
                "local" | "provider_metadata_only" | "placeholder"
            )
        {
            return Ok(false);
        }
        let path = absolute(path)?;
        if !scope.roots.iter().any(|root| path.starts_with(root))
            || !scope.allows(&path)
            || is_index_path(&path, database, sidecars)
        {
            return Ok(false);
        }
        let Some(text) = path.to_str() else {
            return Ok(false);
        };
        let id: Option<i64> = conn
            .prepare_cached(
                "SELECT id FROM item WHERE path=?1 AND kind=?2 AND availability=?3
             AND availability<>'unverified'",
            )?
            .query_row([text, kind, availability], |row| row.get(0))
            .optional()?;
        let Some(id) = id else {
            return Ok(false);
        };
        let Ok(file) = paths.selected_metadata(&path, kind == "directory") else {
            return Ok(false);
        };
        // Require the same path spelling, so a replacement or alias cannot
        // direct the action at a different entry allowed by the filesystem.
        if file.path != path || file.availability != availability {
            return Ok(false);
        }
        let Some(stamp) = stamp else {
            return Ok(true);
        };
        if file.stamp.as_deref() != Some(stamp) {
            return Ok(false);
        }
        if kind == "file" && crate::image_search::stored_match(conn, id, &path, stamp)? {
            return Ok(true);
        }
        if !scope.documents {
            return Ok(false);
        }
        let (column, join) = document_stamp_sql(conn)?;
        let stored = conn
            .query_row(
                &format!("SELECT {column} AS document_stamp FROM document d {join} WHERE d.id=?1"),
                [id],
                read_document_stamp,
            )
            .optional()?
            .flatten();
        Ok(stored.as_deref() == Some(stamp))
    }
}

fn inspect(conn: &Connection, database: &Path, path: &Path) -> Diagnosis {
    let Ok(Some(scope)) = saved_index_scope(conn) else {
        return Diagnosis::blocked(Reason::ScopeUnknown);
    };
    let sidecars = INDEX_SIDECARS.map(|suffix| with_suffix(database, suffix));
    let ruled_out = |path: &Path| {
        if scope.excludes(path) || is_index_path(path, database, &sidecars) {
            Some(Reason::Excluded)
        } else if !scope.roots.iter().any(|root| path.starts_with(root))
            || (!scope.allow.is_empty() && !scope.allow.iter().any(|allow| path.starts_with(allow)))
        {
            Some(Reason::OutsideScope)
        } else {
            None
        }
    };
    if let Some(reason) = ruled_out(path) {
        return Diagnosis::blocked(reason);
    }
    let file = match selected_metadata(path, false) {
        Ok(file) => file,
        Err(reason) => return Diagnosis::blocked(reason),
    };
    if let Some(reason) = ruled_out(&file.path) {
        return Diagnosis::blocked(reason);
    }
    inspect_file(conn, &scope, &file)
}

fn inspect_file(conn: &Connection, scope: &Scope, file: &Selected) -> Diagnosis {
    let Some(path) = file.path.to_str() else {
        return Diagnosis::blocked(Reason::Unsupported);
    };
    let item = conn
        .query_row(
            "SELECT id,kind,availability FROM item WHERE path=?1",
            [path],
            |r| {
                Ok((
                    r.get::<_, i64>(0)?,
                    r.get::<_, String>(1)?,
                    r.get::<_, String>(2)?,
                ))
            },
        )
        .optional();
    let Ok(item) = item else {
        return Diagnosis::blocked(Reason::Unknown);
    };
    let name = match item.as_ref() {
        // Cloud entries are checked by stat alone. A missing exact cache row
        // cannot disambiguate an alternate spelling of their indexed name.
        None if file.availability != "local" => Reason::Unknown,
        None => Reason::NotIndexed,
        Some((_, _, availability)) if availability == "unverified" => Reason::Unverified,
        Some((_, kind, _)) if kind != "file" => Reason::Stale,
        Some(_) => Reason::Indexed,
    };
    let id = item.map(|row| row.0);
    let text = text_state(conn, scope, file, name, id);
    let semantic = match (text, id) {
        (Reason::Indexed, Some(id)) => {
            semantic::diagnose_gemma(conn, id).unwrap_or(Reason::Unknown)
        }
        _ => text,
    };
    Diagnosis {
        name,
        text,
        semantic,
        availability: Some(file.availability),
    }
}

fn text_state(
    conn: &Connection,
    scope: &Scope,
    file: &Selected,
    name: Reason,
    id: Option<i64>,
) -> Reason {
    if file.availability != "local" {
        return Reason::CloudNameOnly;
    }
    if !scope.documents {
        return Reason::TextDisabled;
    }
    if scope
        .content_roots
        .as_ref()
        .is_some_and(|roots| !roots.iter().any(|root| file.path.starts_with(root)))
    {
        return Reason::OutsideContentScope;
    }
    let Some(kind) = DocumentKind::for_path(&file.path) else {
        return Reason::Unsupported;
    };
    if kind == DocumentKind::Image && !scope.image_ocr {
        return Reason::Unsupported;
    }
    if kind == DocumentKind::Pdf
        && scope.pdf_helper.is_none()
        && scope.pdf_helper_policy != Some(PdfHelperPolicy::Bundled)
    {
        return Reason::PdfHelperUnconfigured;
    }
    if name != Reason::Indexed {
        return name;
    }
    let Some(id) = id else {
        return Reason::Unknown;
    };
    let Ok((stamp, join)) = document_stamp_sql(conn) else {
        return Reason::Unknown;
    };
    match conn
        .query_row(
            &format!("SELECT {stamp} AS document_stamp FROM document d {join} WHERE d.id=?1"),
            [id],
            read_document_stamp,
        )
        .optional()
    {
        Ok(None) => Reason::NotIndexed,
        Ok(Some(Some(stamp))) if file.stamp.as_deref() == Some(stamp.as_str()) => Reason::Indexed,
        Ok(Some(Some(_))) => Reason::Stale,
        _ => Reason::Unknown,
    }
}

struct Selected {
    path: PathBuf,
    availability: &'static str,
    stamp: Option<String>,
}

pub(crate) fn local_stamp(path: &Path, directory: bool) -> Option<String> {
    #[cfg(target_os = "macos")]
    let _io = crate::platform::NoMaterialization::enter().ok()?;
    let file = selected_metadata(path, directory).ok()?;
    if file.path != path || file.availability != "local" {
        return None;
    }
    file.stamp
}

fn selected_metadata(path: &Path, directory_hit: bool) -> Result<Selected, Reason> {
    MetadataBatch::default().selected_metadata(path, directory_hit)
}

/// Keep verified parent descriptors and failures for this request only.
/// Each selected leaf is still checked live.
#[derive(Default)]
pub(super) struct MetadataBatch {
    #[cfg(target_os = "macos")]
    directories: HashMap<PathBuf, Result<File, Reason>>,
}

#[cfg(not(target_os = "macos"))]
impl MetadataBatch {
    fn selected_metadata(&mut self, _: &Path, _: bool) -> Result<Selected, Reason> {
        Err(Reason::Unknown)
    }
}

#[cfg(target_os = "macos")]
fn metadata_availability(path: &Path, flags: u32, leaf: bool) -> Result<&'static str, Reason> {
    let dataless = crate::platform::dataless_flags(flags);
    if dataless && !leaf {
        return Err(Reason::CloudAncestor);
    }
    Ok(crate::platform::classify(path, dataless))
}

#[cfg(target_os = "macos")]
const METADATA_ONLY: i32 =
    libc::O_EVTONLY | libc::O_NOFOLLOW_ANY | libc::O_NONBLOCK | libc::O_CLOEXEC;

#[cfg(target_os = "macos")]
fn io_reason(error: io::Error) -> Reason {
    match error.raw_os_error() {
        Some(libc::ENOENT | libc::ENOTDIR) => Reason::Missing,
        Some(libc::EACCES | libc::EPERM) => Reason::Unreadable,
        Some(libc::ELOOP) => Reason::Symlink,
        _ => Reason::Unknown,
    }
}

#[cfg(target_os = "macos")]
impl MetadataBatch {
    fn directory(&mut self, path: &Path) -> Result<&File, Reason> {
        if !self.directories.contains_key(path) {
            let opened = self.open_directory(path);
            self.directories.insert(path.into(), opened);
        }
        self.directories[path].as_ref().map_err(|&reason| reason)
    }

    fn open_directory(&mut self, path: &Path) -> Result<File, Reason> {
        if path == Path::new("/") {
            return OpenOptions::new()
                .read(true)
                .custom_flags(METADATA_ONLY | libc::O_DIRECTORY)
                .open(path)
                .map_err(io_reason);
        }
        let parent = self.directory(path.parent().ok_or(Reason::Unknown)?)?;
        let (name, raw) = stat_component(parent, path)?;
        if raw.st_mode & libc::S_IFMT != libc::S_IFDIR {
            return Err(Reason::Missing);
        }
        metadata_availability(path, raw.st_flags, false)?;
        let (file, metadata) = open_component(parent, &name, &raw, true)?;
        if crate::platform::availability(path, &metadata) == "placeholder" {
            return Err(Reason::CloudAncestor);
        }
        Ok(file)
    }

    fn selected_metadata(&mut self, path: &Path, directory: bool) -> Result<Selected, Reason> {
        use crate::platform::descriptor_path;
        let parent = self.directory(path.parent().ok_or(Reason::NotFile)?)?;
        let (name, raw) = stat_component(parent, path)?;
        let expected = if directory {
            libc::S_IFDIR
        } else {
            libc::S_IFREG
        };
        if raw.st_mode & libc::S_IFMT != expected {
            return Err(Reason::NotFile);
        }
        let availability = metadata_availability(path, raw.st_flags, true)?;
        if availability != "local" {
            // Do not open cloud-only leaves, even for events merely to get their spelling.
            let path = descriptor_path(parent)
                .ok_or(Reason::Unknown)?
                .join(path.file_name().ok_or(Reason::NotFile)?);
            return Ok(Selected {
                path,
                availability,
                stamp: None,
            });
        }
        let (file, metadata) = open_component(parent, &name, &raw, directory)?;
        let path = descriptor_path(&file).ok_or(Reason::Unknown)?;
        let availability = crate::platform::availability(&path, &metadata);
        Ok(Selected {
            path,
            availability,
            stamp: Some(crate::index::stamp(&metadata)),
        })
    }
}

#[cfg(target_os = "macos")]
fn stat_component(directory: &File, path: &Path) -> Result<(CString, libc::stat), Reason> {
    let name = path.file_name().ok_or(Reason::NotFile)?;
    let name = CString::new(name.as_bytes()).map_err(|_| Reason::Unknown)?;
    let mut raw = MaybeUninit::<libc::stat>::uninit();
    // The parent is an already validated descriptor. lstat the one named
    // component so even special files are rejected before opening an fd.
    if unsafe {
        libc::fstatat(
            directory.as_raw_fd(),
            name.as_ptr(),
            raw.as_mut_ptr(),
            libc::AT_SYMLINK_NOFOLLOW,
        )
    } != 0
    {
        return Err(io_reason(io::Error::last_os_error()));
    }
    let raw = unsafe { raw.assume_init() };
    let file_type = raw.st_mode & libc::S_IFMT;
    if file_type == libc::S_IFLNK {
        return Err(Reason::Symlink);
    }
    Ok((name, raw))
}

#[cfg(target_os = "macos")]
fn open_component(
    directory: &File,
    name: &CString,
    raw: &libc::stat,
    is_directory: bool,
) -> Result<(File, std::fs::Metadata), Reason> {
    let flags = METADATA_ONLY | if is_directory { libc::O_DIRECTORY } else { 0 };
    let fd = unsafe { libc::openat(directory.as_raw_fd(), name.as_ptr(), flags) };
    if fd < 0 {
        return Err(io_reason(io::Error::last_os_error()));
    }
    let file = unsafe { File::from_raw_fd(fd) };
    let metadata = file.metadata().map_err(io_reason)?;
    if metadata.file_type().is_symlink() {
        return Err(Reason::Symlink);
    }
    if metadata.dev() != raw.st_dev as u64 || metadata.ino() != raw.st_ino {
        return Err(Reason::Unknown);
    }
    Ok((file, metadata))
}

#[cfg(all(test, target_os = "macos"))]
mod tests {
    use super::*;

    #[test]
    fn catalog_validation_survives_concurrent_benign_commits() {
        let root = std::fs::canonicalize(std::env::temp_dir())
            .unwrap()
            .join(format!("lumen-diagnose-snapshot-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(root.join("docs")).unwrap();
        let path = root.join("docs/file.txt");
        std::fs::write(&path, "document").unwrap();
        let database = root.join("index.db");
        crate::index::scan(
            &database,
            &Scope {
                roots: vec![root.join("docs")],
                ..Scope::default()
            },
        )
        .unwrap();
        let reader = open_read(&database).unwrap();
        let writer = Connection::open(&database).unwrap();
        let validate = |snapshot: &Connection| {
            CatalogValidator::new(snapshot, &database).unwrap().check(
                &mut MetadataBatch::default(),
                &path,
                "file",
                "local",
                None,
            )
        };
        let transaction = reader.unchecked_transaction().unwrap();
        let result = read_snapshot(&transaction, |snapshot| {
            assert!(validate(snapshot));
            for _ in 0..8 {
                writer.execute("UPDATE item SET display=display || 'x'", [])?;
                assert!(validate(snapshot));
            }
            Ok(true)
        })
        .unwrap();
        assert!(result);
        assert!(!reader.is_autocommit());
        transaction.commit().unwrap();
        assert!(validate_catalog_hit(
            &database, &path, "file", "local", None
        ));
        drop(reader);
        drop(writer);
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn batch_reuses_verified_parents_but_checks_each_leaf_and_drops_the_cache() {
        use std::{fs, os::unix::fs::symlink};

        let _io = crate::platform::NoMaterialization::enter().unwrap();
        let root = fs::canonicalize(std::env::temp_dir())
            .unwrap()
            .join(format!("lumen-parent-cache-{}", std::process::id()));
        fs::create_dir(&root).unwrap();
        let parent = root.join("docs");
        let first = parent.join("first.txt");
        let second = parent.join("second.txt");
        let nested = parent.join("subdir/third.txt");
        fs::create_dir_all(nested.parent().unwrap()).unwrap();
        for path in [&first, &second, &nested] {
            fs::write(path, "fixture").unwrap();
        }

        let mut batch = MetadataBatch::default();
        assert_eq!(batch.selected_metadata(&first, false).unwrap().path, first);
        let cached_fd = batch.directories[&parent].as_ref().unwrap().as_raw_fd();
        let prefixes = batch.directories.len();
        assert_eq!(
            batch.selected_metadata(&second, false).unwrap().path,
            second
        );
        assert_eq!(batch.directories.len(), prefixes);
        assert_eq!(
            batch.selected_metadata(&nested, false).unwrap().path,
            nested
        );
        assert_eq!(batch.directories.len(), prefixes + 1);
        assert_eq!(
            batch.directories[&parent].as_ref().unwrap().as_raw_fd(),
            cached_fd
        );

        fs::remove_file(&second).unwrap();
        symlink(&first, &second).unwrap();
        assert!(matches!(
            batch.selected_metadata(&second, false),
            Err(Reason::Symlink)
        ));
        drop(batch);
        let replacement = root.join("moved");
        fs::rename(&parent, &replacement).unwrap();
        symlink(&replacement, &parent).unwrap();
        assert!(matches!(
            selected_metadata(&first, false),
            Err(Reason::Symlink)
        ));
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn synthetic_dataless_flag_preserves_name_and_blocks_cloud_children() {
        let conn = Connection::open_in_memory().unwrap();
        let path = Path::new("/synthetic/online-only.md");
        conn.execute_batch(
            "CREATE TABLE item(id INTEGER PRIMARY KEY,path TEXT,kind TEXT,availability TEXT);
              INSERT INTO item VALUES(1,'/synthetic/online-only.md','file','placeholder');",
        )
        .unwrap();
        let scope = Scope {
            roots: vec!["/synthetic".into()],
            documents: true,
            ..Scope::default()
        };
        let flags = 0x4000_0000;
        assert_eq!(
            metadata_availability(path, flags, false),
            Err(Reason::CloudAncestor)
        );
        let file = Selected {
            path: path.into(),
            availability: metadata_availability(path, flags, true).unwrap(),
            stamp: None,
        };
        let diagnosis = inspect_file(&conn, &scope, &file);
        assert_eq!(diagnosis.name, Reason::Indexed);
        assert_eq!(diagnosis.text, Reason::CloudNameOnly);
        assert_eq!(diagnosis.semantic, Reason::CloudNameOnly);
        assert_eq!(diagnosis.availability, Some("placeholder"));
    }
}
