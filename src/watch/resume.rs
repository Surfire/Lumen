use super::fsevents;
use crate::{Result, Scope, index::Coverage, platform};
use rusqlite::{Connection, OptionalExtension, params};
use serde::{Deserialize, Serialize};
use std::{
    ffi::CStr,
    fs::{self, OpenOptions},
    io,
    mem::{MaybeUninit, size_of},
    os::{
        fd::IntoRawFd,
        unix::{
            ffi::OsStrExt,
            fs::{MetadataExt, OpenOptionsExt},
        },
    },
    path::{Path, PathBuf},
    ptr,
};

const DATA: &str = "/System/Volumes/Data";
const KEY: &str = "watch_checkpoint_v1";

#[derive(Debug, PartialEq, Eq, Serialize, Deserialize)]
struct Identity {
    boot: String,
    uuid: String,
    roots: Vec<(PathBuf, u64, u64)>,
    credentials: (libc::uid_t, libc::gid_t, Vec<libc::gid_t>),
    pdf_helper: Option<(u64, u64, u64, i64, i64)>,
}

pub(super) struct Journal {
    identity: Identity,
    relative: PathBuf,
    pub(super) device: libc::dev_t,
}

impl Journal {
    // The startup Data volume backs the logical writable paths. The sealed
    // read-only system volume cannot change in this boot. Other mount layouts
    // still use the existing host watcher and reconciliation.
    pub(super) fn open(coverage: &Coverage, roots: &[PathBuf]) -> Option<Self> {
        let data = fs::symlink_metadata(DATA).ok()?.dev();
        if data == 0 || roots.is_empty() || other_mount(coverage, roots)? {
            return None;
        }
        let device = data as libc::dev_t;
        let uuid = fsevents::uuid(device)?;
        let boot = boot_session()?;
        let mut identities = Vec::with_capacity(roots.len());
        let mut relative = roots[0].strip_prefix("/").ok()?.to_owned();
        for root in roots {
            let relative_root = root.strip_prefix("/").ok()?;
            let meta = fs::symlink_metadata(root).ok()?;
            if !meta.is_dir() || platform::availability(root, &meta) == "placeholder" {
                return None;
            }
            if root != Path::new("/") {
                let physical = fs::symlink_metadata(Path::new(DATA).join(relative_root)).ok()?;
                if (meta.dev(), meta.ino()) != (data, physical.ino()) || physical.dev() != data {
                    return None;
                }
            }
            while !relative_root.starts_with(&relative) {
                if !relative.pop() {
                    return None;
                }
            }
            identities.push((root.clone(), meta.dev(), meta.ino()));
        }
        let mut groups = [0; 128];
        let count = unsafe { libc::getgroups(groups.len() as i32, groups.as_mut_ptr()) };
        if count < 0 {
            return None;
        }
        let mut groups = groups[..count as usize].to_vec();
        groups.sort_unstable();
        let pdf_helper = match &coverage.scope.pdf_helper {
            Some(path) => {
                let file = fs::metadata(path).ok()?;
                Some((
                    file.dev(),
                    file.ino(),
                    file.len(),
                    file.ctime(),
                    file.ctime_nsec(),
                ))
            }
            None => None,
        };
        Some(Self {
            identity: Identity {
                boot,
                uuid,
                roots: identities,
                credentials: (
                    unsafe { libc::geteuid() },
                    unsafe { libc::getegid() },
                    groups,
                ),
                pdf_helper,
            },
            relative,
            device,
        })
    }

    pub(super) fn paths(&self) -> Vec<PathBuf> {
        vec![self.relative.clone()]
    }

    pub(super) fn unchanged(&self, coverage: &Coverage, roots: &[PathBuf]) -> bool {
        Self::open(coverage, roots).is_some_and(|current| current.identity == self.identity)
    }

    pub(super) fn current_id(&self) -> Option<u64> {
        fsevents::current_id()
    }

    pub(super) fn load(&self, conn: &Connection, scope: &Scope) -> Result<Option<u64>> {
        let raw: Option<String> = conn
            .query_row("SELECT value FROM info WHERE key=?1", [KEY], |row| {
                row.get(0)
            })
            .optional()?;
        let Some((identity, saved_scope, id)) = raw
            .as_deref()
            .and_then(|raw| serde_json::from_str::<(Identity, Scope, u64)>(raw).ok())
        else {
            return Ok(None);
        };
        Ok((identity == self.identity
            && &saved_scope == scope
            && id != 0
            && self.current_id().is_some_and(|latest| id <= latest))
        .then_some(id))
    }

    pub(super) fn save(&self, conn: &Connection, scope: &Scope, id: u64) -> Result<()> {
        // This statement runs only after the indexed mutations are committed.
        // A crash between those commits repeats work from the older cursor.
        conn.execute(
            "INSERT INTO info(key,value) VALUES(?1,?2)
             ON CONFLICT(key) DO UPDATE SET value=excluded.value WHERE value<>excluded.value",
            params![KEY, serde_json::to_string(&(&self.identity, scope, id))?],
        )?;
        Ok(())
    }
}

pub(super) fn invalidate(conn: &Connection) -> Result<()> {
    conn.execute("DELETE FROM info WHERE key=?1", [KEY])?;
    Ok(())
}

pub(super) fn install_invalidation(conn: &Connection) -> Result<()> {
    // A manual scan, scope change, or an older watcher can update the catalog
    // independently. Invalidate the cursor in the same transaction as that write.
    conn.execute_batch(
        "CREATE TRIGGER IF NOT EXISTS watch_checkpoint_insert AFTER INSERT ON info
         WHEN NEW.key IN('scan','scope') BEGIN
           DELETE FROM info WHERE key='watch_checkpoint_v1';
         END;
         CREATE TRIGGER IF NOT EXISTS watch_checkpoint_update AFTER UPDATE ON info
         WHEN OLD.key IN('scan','scope') OR NEW.key IN('scan','scope') BEGIN
           DELETE FROM info WHERE key='watch_checkpoint_v1';
         END;
         CREATE TRIGGER IF NOT EXISTS watch_checkpoint_delete AFTER DELETE ON info
         WHEN OLD.key IN('scan','scope') BEGIN
           DELETE FROM info WHERE key='watch_checkpoint_v1';
         END;",
    )?;
    Ok(())
}

fn boot_session() -> Option<String> {
    let mut buffer = [0; 64];
    let mut len = buffer.len();
    let result = unsafe {
        libc::sysctlbyname(
            c"kern.bootsessionuuid".as_ptr(),
            buffer.as_mut_ptr().cast(),
            &mut len,
            ptr::null_mut(),
            0,
        )
    };
    if result != 0 || len == 0 || len > buffer.len() {
        return None;
    }
    CStr::from_bytes_until_nul(&buffer[..len])
        .ok()?
        .to_str()
        .ok()
        .map(str::to_owned)
}

fn other_mount(coverage: &Coverage, roots: &[PathBuf]) -> Option<bool> {
    // Use our own buffer because getmntinfo's shared buffer could be
    // invalidated by another thread calling into the system frameworks.
    let count = unsafe { libc::getfsstat(ptr::null_mut(), 0, libc::MNT_NOWAIT) };
    let capacity = usize::try_from(count).ok()?.checked_add(8)?;
    let bytes = capacity
        .checked_mul(size_of::<libc::statfs>())?
        .try_into()
        .ok()?;
    let mut mounts = vec![MaybeUninit::<libc::statfs>::uninit(); capacity];
    let count = unsafe { libc::getfsstat(mounts.as_mut_ptr().cast(), bytes, libc::MNT_NOWAIT) };
    let count = usize::try_from(count).ok()?;
    if count == 0 || count >= capacity {
        return None;
    }
    let mut readonly_root = false;
    for mount in &mounts[..count] {
        let mount = unsafe { mount.assume_init_ref() };
        let path = unsafe { CStr::from_ptr(mount.f_mntonname.as_ptr()) }.to_bytes();
        let path = Path::new(std::ffi::OsStr::from_bytes(path));
        if path == Path::new("/") {
            let kind = unsafe { CStr::from_ptr(mount.f_fstypename.as_ptr()) };
            readonly_root = kind == c"apfs" && mount.f_flags & libc::MNT_RDONLY as u32 != 0;
        } else if path != Path::new(DATA) {
            let logical = path
                .strip_prefix(DATA)
                .ok()
                .map(|suffix| Path::new("/").join(suffix));
            let path = logical.as_deref().unwrap_or(path);
            if roots.iter().any(|root| path.starts_with(root)) && coverage.allows(path) {
                let through_link = logical.is_some()
                    && path.ancestors().any(|part| {
                        fs::symlink_metadata(part).is_ok_and(|m| m.file_type().is_symlink())
                    });
                if !through_link {
                    return Some(true);
                }
            }
        }
    }
    Some(!readonly_root && roots.iter().any(|root| root == Path::new("/")))
}

fn open_directory(path: &Path) -> io::Result<()> {
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW_ANY)
        .open(path)?;
    if platform::availability(path, &file.metadata()?) == "placeholder" {
        return Err(io::Error::from(io::ErrorKind::PermissionDenied));
    }
    let fd = file.into_raw_fd();
    let dir = unsafe { libc::fdopendir(fd) };
    if dir.is_null() {
        let error = io::Error::last_os_error();
        unsafe { libc::close(fd) };
        return Err(error);
    }
    unsafe {
        *libc::__error() = 0;
        let entry = libc::readdir(dir);
        let error = *libc::__error();
        libc::closedir(dir);
        if entry.is_null() && error != 0 {
            Err(io::Error::from_raw_os_error(error))
        } else {
            Ok(())
        }
    }
}

fn open_document(path: &Path) -> bool {
    fs::symlink_metadata(path).is_ok_and(|metadata| {
        metadata.is_file()
            && platform::availability(path, &metadata) == "local"
            && OpenOptions::new()
                .read(true)
                .custom_flags(libc::O_NOFOLLOW_ANY | libc::O_NONBLOCK)
                .open(path)
                .is_ok_and(|file| {
                    file.metadata().is_ok_and(|opened| {
                        opened.is_file()
                            && (opened.dev(), opened.ino()) == (metadata.dev(), metadata.ino())
                            && platform::availability(path, &opened) == "local"
                    })
                })
    })
}

pub(super) fn verify_access(conn: &mut Connection, roots: Option<&[PathBuf]>) -> Result<bool> {
    // Directory enumeration controls name visibility in the normal walker.
    // Also verify access to each cached document without reading its bytes.
    // The watcher's no-materialization I/O policy covers both operations.
    let mut blocked = Vec::new();
    let mut opened_previously_blocked = false;
    for path in roots.into_iter().flatten() {
        if open_directory(path).is_err() {
            blocked.push(path.to_string_lossy().into_owned());
        }
    }
    {
        let mut statement = conn.prepare(
            "SELECT path, 1, availability='unverified' FROM item
               WHERE ?1 AND kind='directory' AND availability<>'placeholder'
             UNION ALL
             SELECT item.path, 0, item.availability='unverified' FROM document JOIN item USING(id)
               WHERE ?1 OR item.availability<>'unverified'",
        )?;
        let mut rows = statement.query([roots.is_some()])?;
        while let Some(row) = rows.next()? {
            let name: String = row.get(0)?;
            let path = Path::new(&name);
            let directory: bool = row.get(1)?;
            let accessible = if directory {
                open_directory(path).is_ok()
            } else {
                open_document(path)
            };
            let previously_blocked: bool = row.get(2)?;
            if !accessible && !previously_blocked {
                blocked.push(name);
            }
            opened_previously_blocked |= accessible && previously_blocked;
        }
    }
    if blocked.is_empty() {
        return Ok(!opened_previously_blocked);
    }
    blocked.sort_unstable();
    let mut covered: Option<&str> = None;
    let tx = conn.transaction()?;
    for path in &blocked {
        if covered.is_some_and(|parent| Path::new(path).starts_with(parent)) {
            continue;
        }
        // The same exclusive end of the slash-delimited subtree used by the
        // indexer. Removing the document stamp forces the next scan to retry
        // authorization instead of reusing an unchanged extracted document.
        let path_without_slash = path.trim_end_matches('/');
        let start = format!("{path_without_slash}/");
        let end = format!("{path_without_slash}0");
        tx.execute(
            "UPDATE item SET availability='unverified'
             WHERE availability <> 'unverified' AND (path=?1 OR (path>=?2 AND path<?3))",
            params![path, start, end],
        )?;
        tx.execute(
            "DELETE FROM document_state WHERE id IN
             (SELECT id FROM item WHERE path=?1 OR (path>=?2 AND path<?3))",
            params![path, start, end],
        )?;
        covered = Some(path);
    }
    invalidate(&tx)?;
    tx.commit()?;
    Ok(false)
}
