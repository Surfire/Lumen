//! Single-path diagnostics. The selected file contributes metadata, never bytes.
use crate::{
    PdfHelperPolicy, Scope, absolute, document_stamp_sql,
    index::{DocumentKind, INDEX_SIDECARS, is_index_path},
    open_read, read_document_stamp, saved_index_scope, semantic, with_suffix,
};
use rusqlite::{Connection, OptionalExtension};
use serde::Serialize;
use std::path::{Component, Path, PathBuf};

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
    if crate::external::is_external(path) {
        return crate::external::validate(database, path, kind, availability, stamp);
    }
    validate_catalog_hit(database, path, kind, availability, stamp)
}

pub(super) fn validate_catalog_hit(
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
    if !path.is_absolute() || path.components().any(|c| c == Component::ParentDir) {
        return false;
    }
    let result = (|| -> crate::Result<bool> {
        let database = absolute(database)?;
        let conn = open_read(&database)?;
        let sidecars = INDEX_SIDECARS.map(|suffix| with_suffix(&database, suffix));
        Ok(read_snapshot(&conn, |snapshot| {
            let Some(scope) = saved_index_scope(snapshot)? else {
                return Ok(false);
            };
            validate_in_snapshot(
                snapshot,
                (&scope, &database, &sidecars),
                path,
                kind,
                availability,
                stamp,
            )
        })?
        .unwrap_or(false))
    })();
    result.unwrap_or(false)
}

/// Validate an ordered batch using the session's existing catalog connection.
/// The metadata checks never read the selected files' contents.
pub(super) fn validate_session_hits(
    conn: &Connection,
    database: &Path,
    hits: &[(&str, &str, &str, Option<&str>)],
) -> Vec<bool> {
    #[cfg(target_os = "macos")]
    let Ok(_io) = crate::platform::NoMaterialization::enter() else {
        return vec![false; hits.len()];
    };
    let Ok(snapshot) = conn.unchecked_transaction() else {
        return vec![false; hits.len()];
    };
    let scope = saved_index_scope(&snapshot).ok().flatten();
    let sidecars = INDEX_SIDECARS.map(|suffix| with_suffix(database, suffix));
    hits.iter()
        .map(|&(path, kind, availability, stamp)| {
            let path = Path::new(path);
            if !path.is_absolute() || path.components().any(|c| c == Component::ParentDir) {
                return false;
            }
            if crate::external::is_external(path) {
                return crate::external::validate(database, path, kind, availability, stamp);
            }
            scope.as_ref().is_some_and(|scope| {
                validate_in_snapshot(
                    &snapshot,
                    (scope, database, &sidecars),
                    path,
                    kind,
                    availability,
                    stamp,
                )
                .unwrap_or(false)
            })
        })
        .collect()
}

/// Retry a read raced by a catalog commit without repeating work outside SQLite.
/// A continuously changing catalog still has a bounded, fail-closed fallback.
pub(super) fn read_snapshot<T>(
    conn: &Connection,
    mut read: impl FnMut(&Connection) -> crate::Result<T>,
) -> crate::Result<Option<T>> {
    for _ in 0..3 {
        let before = crate::name_fast::data_version(conn)?;
        let snapshot = conn.unchecked_transaction()?;
        let value = read(&snapshot)?;
        drop(snapshot);
        if before == crate::name_fast::data_version(conn)? {
            return Ok(Some(value));
        }
    }
    Ok(None)
}

fn validate_in_snapshot(
    conn: &Connection,
    (scope, database, sidecars): (&Scope, &Path, &[PathBuf]),
    path: &Path,
    kind: &str,
    availability: &str,
    stamp: Option<&str>,
) -> crate::Result<bool> {
    if !matches!(kind, "file" | "directory")
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
    let Ok(file) = selected_metadata(&path, kind == "directory") else {
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

#[cfg(not(target_os = "macos"))]
fn selected_metadata(_: &Path, _: bool) -> Result<Selected, Reason> {
    Err(Reason::Unknown)
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
fn selected_metadata(path: &Path, directory_hit: bool) -> Result<Selected, Reason> {
    use crate::platform::descriptor_path;
    use std::{
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

    fn io_reason(error: io::Error) -> Reason {
        match error.raw_os_error() {
            Some(libc::ENOENT | libc::ENOTDIR) => Reason::Missing,
            Some(libc::EACCES | libc::EPERM) => Reason::Unreadable,
            Some(libc::ELOOP) => Reason::Symlink,
            _ => Reason::Unknown,
        }
    }

    const METADATA_ONLY: i32 = libc::O_EVTONLY | libc::O_NOFOLLOW | libc::O_NONBLOCK;
    let mut directory = OpenOptions::new()
        .read(true)
        .custom_flags(METADATA_ONLY | libc::O_DIRECTORY)
        .open("/")
        .map_err(io_reason)?;
    let mut parts = path.components().skip(1).peekable();
    while let Some(part) = parts.next() {
        let leaf = parts.peek().is_none();
        let name = CString::new(part.as_os_str().as_bytes()).map_err(|_| Reason::Unknown)?;
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
        let expected_leaf = if directory_hit {
            libc::S_IFDIR
        } else {
            libc::S_IFREG
        };
        if leaf && file_type != expected_leaf {
            return Err(Reason::NotFile);
        }
        if !leaf && file_type != libc::S_IFDIR {
            return Err(Reason::Missing);
        }
        let availability = metadata_availability(path, raw.st_flags, leaf)?;
        if leaf && availability != "local" {
            // Stat already proves the entry is cloud metadata only. Do not
            // open it even for events merely to resolve its stored spelling.
            let path = descriptor_path(&directory)
                .ok_or(Reason::Unknown)?
                .join(part);
            return Ok(Selected {
                path,
                availability,
                stamp: None,
            });
        }
        let flags = if !leaf || directory_hit {
            METADATA_ONLY | libc::O_DIRECTORY
        } else {
            METADATA_ONLY
        };
        let fd = unsafe {
            libc::openat(
                directory.as_raw_fd(),
                name.as_ptr(),
                flags | libc::O_CLOEXEC,
            )
        };
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
        if leaf {
            let path = descriptor_path(&file).ok_or(Reason::Unknown)?;
            let availability = crate::platform::availability(&path, &metadata);
            return Ok(Selected {
                path,
                availability,
                stamp: Some(crate::index::stamp(&metadata)),
            });
        }
        if crate::platform::availability(path, &metadata) == "placeholder" {
            return Err(Reason::CloudAncestor);
        }
        directory = file;
    }
    Err(Reason::NotFile)
}

#[cfg(all(test, target_os = "macos"))]
mod tests {
    use super::*;

    #[test]
    fn catalog_validation_retries_concurrent_commits_and_is_bounded() {
        let root = std::fs::canonicalize(std::env::temp_dir())
            .unwrap()
            .join(format!("lumen-snapshot-retry-{}", std::process::id()));
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
        let scope = saved_index_scope(&reader).unwrap().unwrap();
        let sidecars = INDEX_SIDECARS.map(|suffix| with_suffix(&database, suffix));
        let context = (&scope, database.as_path(), sidecars.as_slice());
        let mut attempts = 0;
        let result = read_snapshot(&reader, |snapshot| {
            attempts += 1;
            let visible = validate_in_snapshot(snapshot, context, &path, "file", "local", None)?;
            if attempts < 3 {
                writer.execute("UPDATE item SET display=display || 'x'", [])?;
            }
            Ok(visible)
        })
        .unwrap();
        assert_eq!(result, Some(true));
        assert_eq!(attempts, 3);
        assert!(validate_catalog_hit(
            &database, &path, "file", "local", None
        ));

        attempts = 0;
        let result = read_snapshot(&reader, |snapshot| {
            attempts += 1;
            let visible = validate_in_snapshot(snapshot, context, &path, "file", "local", None)?;
            writer.execute("UPDATE item SET display=display || 'x'", [])?;
            Ok(visible)
        })
        .unwrap();
        assert_eq!(result, None);
        assert_eq!(attempts, 3);
        drop(reader);
        drop(writer);
        std::fs::remove_dir_all(root).unwrap();
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
