use crate::{
    Hit, Mode, Result, absolute,
    diagnose::{CatalogValidator, HitInput, MetadataBatch},
    open_read, with_suffix,
};
use anyhow::{Context, bail, ensure};
use rusqlite::{Connection, params};
use serde::{Deserialize, Serialize};
use std::{
    collections::{HashMap, HashSet},
    fs,
    os::unix::fs::{MetadataExt, PermissionsExt},
    path::{Path, PathBuf},
    sync::{Mutex, OnceLock},
};

#[cfg(target_os = "macos")]
mod macos;

const KEY: &str = "external_volume";

/// How a mount instance is identified. Physical media are bound to one boot
/// session and IOKit registry entry; network shares are bound to their
/// credential-free source so a NAS reboot or reconnect keeps the catalog.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) enum MountKind {
    Physical {
        media_id: u64,
        filesystem_id: [i32; 2],
        boot: String,
    },
    Network {
        protocol: String,
        sanitized_source: String,
    },
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(try_from = "MountWire", into = "MountWire")]
pub(super) struct Mount {
    pub(super) path: PathBuf,
    uuid: String,
    kind: MountKind,
}

impl Mount {
    fn kind_label(&self) -> &'static str {
        match self.kind {
            MountKind::Physical { .. } => "external",
            MountKind::Network { .. } => "network",
        }
    }

    fn protocol(&self) -> Option<&str> {
        match &self.kind {
            MountKind::Physical { .. } => None,
            MountKind::Network { protocol, .. } => Some(protocol),
        }
    }
}

/// Sidecar registration JSON. Registrations written before `mount_kind`
/// existed carry top-level physical fields (and an ignored `source`).
#[derive(Serialize, Deserialize)]
struct MountWire {
    path: PathBuf,
    uuid: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    mount_kind: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    filesystem_id: Option<[i32; 2]>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    media_id: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    boot: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    protocol: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    sanitized_source: Option<String>,
}

impl TryFrom<MountWire> for Mount {
    type Error = &'static str;

    fn try_from(wire: MountWire) -> std::result::Result<Self, Self::Error> {
        let kind = match wire.mount_kind.as_deref() {
            None | Some("physical") => MountKind::Physical {
                media_id: wire.media_id.ok_or("physical mount without media_id")?,
                filesystem_id: wire
                    .filesystem_id
                    .ok_or("physical mount without filesystem_id")?,
                boot: wire.boot.ok_or("physical mount without boot session")?,
            },
            Some("network") => MountKind::Network {
                protocol: wire.protocol.ok_or("network mount without protocol")?,
                sanitized_source: wire
                    .sanitized_source
                    .ok_or("network mount without source")?,
            },
            Some(_) => return Err("unknown mount kind"),
        };
        Ok(Self {
            path: wire.path,
            uuid: wire.uuid,
            kind,
        })
    }
}

impl From<Mount> for MountWire {
    fn from(mount: Mount) -> Self {
        let mut wire = Self {
            path: mount.path,
            uuid: mount.uuid,
            mount_kind: None,
            filesystem_id: None,
            media_id: None,
            boot: None,
            protocol: None,
            sanitized_source: None,
        };
        match mount.kind {
            MountKind::Physical {
                media_id,
                filesystem_id,
                boot,
            } => {
                wire.mount_kind = Some("physical".into());
                wire.media_id = Some(media_id);
                wire.filesystem_id = Some(filesystem_id);
                wire.boot = Some(boot);
            }
            MountKind::Network {
                protocol,
                sanitized_source,
            } => {
                wire.mount_kind = Some("network".into());
                wire.protocol = Some(protocol);
                wire.sanitized_source = Some(sanitized_source);
            }
        }
        wire
    }
}

#[derive(Clone)]
pub(super) struct Boundary {
    root: PathBuf,
    device: Option<u64>,
    nested: Vec<PathBuf>,
}

impl Boundary {
    pub(super) fn root(&self) -> &Path {
        &self.root
    }

    pub(super) fn device(&self) -> Option<u64> {
        self.device
    }

    pub(super) fn allows(&self, path: &Path) -> bool {
        path.starts_with(&self.root) && !self.nested.iter().any(|nested| path.starts_with(nested))
    }
}

#[derive(Default)]
struct Mounted {
    eligible: Vec<Mount>,
    points: Vec<PathBuf>,
}

impl Mounted {
    fn boundary(&self, volume: &Mount) -> Boundary {
        Boundary {
            root: volume.path.clone(),
            device: None,
            nested: self
                .points
                .iter()
                .filter(|p| *p != &volume.path && p.starts_with(&volume.path))
                .cloned()
                .collect(),
        }
    }

    /// Physical identities include the boot session and media registry entry,
    /// so equality is a strict mount-instance check. Network identities hold
    /// only uuid, path, protocol and sanitized source, so the same share
    /// reconnected at the same mount point (e.g. after a NAS reboot) matches.
    fn matches(&self, volume: &Mount) -> bool {
        let mut matches = self
            .eligible
            .iter()
            .filter(|mounted| mounted.uuid == volume.uuid);
        matches.next() == Some(volume) && matches.next().is_none()
    }
}

fn mounted() -> Mounted {
    #[cfg(target_os = "macos")]
    return macos::mounted().unwrap_or_default();
    #[cfg(not(target_os = "macos"))]
    Mounted::default()
}

pub(super) fn is_external(path: &Path) -> bool {
    path.is_absolute()
        && path
            .components()
            .nth(1)
            .is_some_and(|part| part.as_os_str().eq_ignore_ascii_case("Volumes"))
}

fn folder(database: &Path) -> Result<PathBuf> {
    Ok(with_suffix(&absolute(database)?, "-external"))
}

fn uuid_valid(uuid: &str) -> bool {
    uuid.len() == 36
        && uuid.bytes().enumerate().all(|(i, c)| {
            if matches!(i, 8 | 13 | 18 | 23) {
                c == b'-'
            } else {
                c.is_ascii_hexdigit()
            }
        })
}

fn check_folder_meta(meta: &fs::Metadata) -> Result<()> {
    ensure!(
        meta.is_dir()
            && meta.uid() == unsafe { libc::geteuid() }
            && meta.permissions().mode() & 0o077 == 0,
        "external volume catalog must be in a user-only directory"
    );
    Ok(())
}

fn check_folder(path: &Path) -> Result<()> {
    check_folder_meta(&fs::symlink_metadata(path)?)
}

fn catalogs_in_dir(folder: &Path) -> Vec<PathBuf> {
    let mut paths: Vec<_> = fs::read_dir(folder)
        .into_iter()
        .flatten()
        .flatten()
        .filter_map(|entry| {
            let path = entry.path();
            (path.extension().is_some_and(|e| e == "sqlite")
                && path
                    .file_stem()
                    .and_then(|s| s.to_str())
                    .is_some_and(uuid_valid)
                && entry.file_type().is_ok_and(|f| f.is_file()))
            .then_some(path)
        })
        .collect();
    paths.sort();
    paths
}

fn registration(conn: &Connection) -> Option<Mount> {
    let value: String = conn
        .query_row("SELECT value FROM info WHERE key=?1", [KEY], |row| {
            row.get(0)
        })
        .ok()?;
    let volume: Mount = serde_json::from_str(&value).ok()?;
    (uuid_valid(&volume.uuid) && volume.path.parent() == Some(Path::new("/Volumes")))
        .then_some(volume)
}

#[derive(Clone, Copy, PartialEq, Eq)]
struct DirStamp {
    dev: u64,
    ino: u64,
    size: u64,
    nlink: u64,
    mtime: i64,
    mtime_nsec: i64,
    ctime: i64,
    ctime_nsec: i64,
}

impl DirStamp {
    fn of(meta: &fs::Metadata) -> Self {
        Self {
            dev: meta.dev(),
            ino: meta.ino(),
            size: meta.size(),
            nlink: meta.nlink(),
            mtime: meta.mtime(),
            mtime_nsec: meta.mtime_nsec(),
            ctime: meta.ctime(),
            ctime_nsec: meta.ctime_nsec(),
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
struct FileId {
    dev: u64,
    ino: u64,
}

impl FileId {
    fn of(meta: &fs::Metadata) -> Self {
        Self {
            dev: meta.dev(),
            ino: meta.ino(),
        }
    }
}

struct CachedSidecar {
    path: PathBuf,
    file_id: FileId,
    conn: Connection,
    reg_version: i64,
    mount: Option<Mount>,
}

impl CachedSidecar {
    fn open(path: PathBuf, file_id: FileId) -> Option<Self> {
        #[cfg(test)]
        test_counters::record_sidecar_open();
        let conn = open_read(&path).ok()?;
        let (reg_version, mount) = read_sidecar_registration(&conn, &path)?;
        Some(Self {
            path,
            file_id,
            conn,
            reg_version,
            mount,
        })
    }

    fn refresh(&mut self) -> bool {
        let Ok(version) = crate::name_fast::data_version(&self.conn) else {
            return false;
        };
        if version == self.reg_version {
            return true;
        }
        let Some((reg_version, mount)) = read_sidecar_registration(&self.conn, &self.path) else {
            return false;
        };
        self.reg_version = reg_version;
        self.mount = mount;
        true
    }
}

fn read_sidecar_registration(conn: &Connection, path: &Path) -> Option<(i64, Option<Mount>)> {
    crate::diagnose::read_snapshot(conn, |snapshot| {
        let version = crate::name_fast::data_version(snapshot)?;
        let mount = registration(snapshot).filter(|volume| {
            path.file_stem()
                .and_then(|s| s.to_str())
                .is_some_and(|stem| stem == volume.uuid)
        });
        Ok((version, mount))
    })
    .ok()
}

struct CachedPrimary {
    file_id: FileId,
    conn: Connection,
    deny_version: i64,
    deny: Option<Vec<PathBuf>>,
}

fn read_primary_deny(conn: &Connection) -> Result<(i64, Option<Vec<PathBuf>>)> {
    crate::diagnose::read_snapshot(conn, |snapshot| {
        let version = crate::name_fast::data_version(snapshot)?;
        let deny = crate::saved_index_scope(snapshot)?.map(|scope| scope.deny);
        Ok((version, deny))
    })
}

#[derive(Default)]
struct DatabaseCache {
    primary: Option<CachedPrimary>,
    dir_stamp: Option<DirStamp>,
    sidecars: Vec<CachedSidecar>,
}

impl DatabaseCache {
    fn deny_rules(&mut self, database: &Path) -> Result<Vec<PathBuf>> {
        let meta = fs::symlink_metadata(database)?;
        ensure!(meta.is_file(), "index is not a regular file");
        let id = FileId::of(&meta);
        if let Some(primary) = &mut self.primary {
            if primary.file_id == id {
                let version = crate::name_fast::data_version(&primary.conn)?;
                if version != primary.deny_version {
                    let (new_version, new_deny) = read_primary_deny(&primary.conn)?;
                    primary.deny_version = new_version;
                    primary.deny = new_deny;
                }
                return primary
                    .deny
                    .clone()
                    .context("main catalog scope is not verified");
            }
            self.primary = None;
        }
        #[cfg(test)]
        test_counters::record_primary_open();
        let conn = open_read(database)?;
        let (deny_version, deny) = read_primary_deny(&conn)?;
        self.primary = Some(CachedPrimary {
            file_id: id,
            conn,
            deny_version,
            deny: deny.clone(),
        });
        deny.context("main catalog scope is not verified")
    }

    fn refresh_sidecars(&mut self, database: &Path) {
        let Ok(dir) = folder(database) else {
            self.clear_sidecars();
            return;
        };
        let Ok(meta) = fs::symlink_metadata(&dir) else {
            self.clear_sidecars();
            return;
        };
        if check_folder_meta(&meta).is_err() {
            self.clear_sidecars();
            return;
        }
        let stamp = DirStamp::of(&meta);
        if self.dir_stamp == Some(stamp) && self.reuse_cached_sidecars() {
            return;
        }
        self.rescan_sidecars(&dir, stamp);
    }

    fn clear_sidecars(&mut self) {
        self.dir_stamp = None;
        self.sidecars.clear();
    }

    fn reuse_cached_sidecars(&mut self) -> bool {
        for sidecar in &mut self.sidecars {
            let Ok(meta) = fs::symlink_metadata(&sidecar.path) else {
                return false;
            };
            if !meta.is_file() || FileId::of(&meta) != sidecar.file_id || !sidecar.refresh() {
                return false;
            }
        }
        true
    }

    fn rescan_sidecars(&mut self, dir: &Path, stamp: DirStamp) {
        #[cfg(test)]
        test_counters::record_dir_scan();
        let paths = catalogs_in_dir(dir);
        let mut previous: HashMap<PathBuf, CachedSidecar> = self
            .sidecars
            .drain(..)
            .map(|entry| (entry.path.clone(), entry))
            .collect();
        let mut next = Vec::with_capacity(paths.len());
        for path in paths {
            let Ok(meta) = fs::symlink_metadata(&path) else {
                continue;
            };
            if !meta.is_file() {
                continue;
            }
            let id = FileId::of(&meta);
            let cached = match previous.remove(&path) {
                Some(mut existing) if existing.file_id == id => {
                    existing.refresh().then_some(existing)
                }
                _ => CachedSidecar::open(path, id),
            };
            if let Some(entry) = cached {
                next.push(entry);
            }
        }
        self.sidecars = next;
        self.dir_stamp = Some(stamp);
    }

    fn active_indices(&self) -> Vec<usize> {
        let mut seen = HashSet::new();
        let mut indices = Vec::new();
        for (i, sidecar) in self.sidecars.iter().enumerate() {
            if let Some(mount) = &sidecar.mount
                && seen.insert(mount.uuid.clone())
            {
                indices.push(i);
            }
        }
        indices
    }
}

const MAX_CACHED_DATABASES: usize = 8;

#[derive(Default)]
struct ExternalCacheRegistry {
    epoch: u64,
    entries: HashMap<PathBuf, DatabaseCache>,
    order: Vec<PathBuf>,
}

fn cache_registry() -> &'static Mutex<ExternalCacheRegistry> {
    static CACHE: OnceLock<Mutex<ExternalCacheRegistry>> = OnceLock::new();
    CACHE.get_or_init(Default::default)
}

struct CacheLease {
    key: PathBuf,
    epoch: u64,
    cache: Option<DatabaseCache>,
}

impl CacheLease {
    fn acquire(database: &Path) -> Result<Self> {
        let key = absolute(database)?;
        let mut guard = cache_registry().lock().unwrap();
        let epoch = guard.epoch;
        let cache = guard.entries.remove(&key).unwrap_or_default();
        guard.order.retain(|item| item != &key);
        Ok(Self {
            key,
            epoch,
            cache: Some(cache),
        })
    }
}

impl Drop for CacheLease {
    fn drop(&mut self) {
        let Some(cache) = self.cache.take() else {
            return;
        };
        let mut guard = cache_registry().lock().unwrap();
        if guard.epoch != self.epoch {
            return;
        }
        let ExternalCacheRegistry { entries, order, .. } = &mut *guard;
        entries.retain(|path, _| path.exists());
        order.retain(|path| entries.contains_key(path));
        if entries.len() >= MAX_CACHED_DATABASES
            && let Some(oldest) = order.first().cloned()
        {
            order.remove(0);
            entries.remove(&oldest);
        }
        entries.insert(self.key.clone(), cache);
        order.push(self.key.clone());
    }
}

fn invalidate_cache(database: &Path) {
    let key = absolute(database).unwrap_or_else(|_| database.to_path_buf());
    let mut guard = cache_registry().lock().unwrap();
    guard.epoch = guard.epoch.wrapping_add(1);
    guard.entries.remove(&key);
    guard.order.retain(|item| item != &key);
}

#[cfg(test)]
mod test_counters {
    use std::cell::Cell;

    thread_local! {
        static DIR_SCANS: Cell<usize> = const { Cell::new(0) };
        static SIDECAR_OPENS: Cell<usize> = const { Cell::new(0) };
        static PRIMARY_OPENS: Cell<usize> = const { Cell::new(0) };
    }

    pub(super) fn record_dir_scan() {
        DIR_SCANS.with(|count| count.set(count.get() + 1));
    }

    pub(super) fn record_sidecar_open() {
        SIDECAR_OPENS.with(|count| count.set(count.get() + 1));
    }

    pub(super) fn record_primary_open() {
        PRIMARY_OPENS.with(|count| count.set(count.get() + 1));
    }

    pub(super) fn snapshot() -> (usize, usize, usize) {
        (
            DIR_SCANS.with(Cell::get),
            SIDECAR_OPENS.with(Cell::get),
            PRIMARY_OPENS.with(Cell::get),
        )
    }
}

#[derive(Serialize)]
pub struct VolumeStatus {
    uuid: String,
    path: PathBuf,
    /// "external" for physical media, "network" for SMB/NFS/AFP/WebDAV shares.
    #[serde(default)]
    pub kind: String,
    /// Normalized network protocol ("smb", "nfs", "afp", "webdav").
    #[serde(default)]
    pub protocol: Option<String>,
    /// An eligible physical or network volume is mounted here now.
    available: bool,
    /// A valid catalog is bound to this mount instance.
    indexed: bool,
    /// An older snapshot exists and needs an explicit refresh.
    needs_refresh: bool,
}

pub fn volumes(database: &Path) -> Vec<VolumeStatus> {
    let Ok(mut lease) = CacheLease::acquire(database) else {
        return Vec::new();
    };
    let cache = lease.cache.as_mut().unwrap();
    let (deny, registered) = match cache.deny_rules(&lease.key) {
        Ok(deny) => {
            cache.refresh_sidecars(&lease.key);
            let registered = cache
                .active_indices()
                .into_iter()
                .filter_map(|i| cache.sidecars[i].mount.clone())
                .collect::<Vec<_>>();
            (deny, registered)
        }
        // Before first indexing the panel can list eligible devices, but
        // publishing an existing catalog requires a verified primary scope.
        Err(_) if database.try_exists().is_ok_and(|exists| !exists) => (Vec::new(), Vec::new()),
        Err(_) => return Vec::new(),
    };
    let attached = mounted();
    let uuids: std::collections::BTreeSet<_> = registered
        .iter()
        .chain(&attached.eligible)
        .map(|volume| &volume.uuid)
        .collect();
    uuids
        .into_iter()
        .filter_map(|uuid| {
            let old = registered.iter().find(|volume| &volume.uuid == uuid);
            let current = attached
                .eligible
                .iter()
                .find(|volume| &volume.uuid == uuid && attached.matches(volume));
            let indexed = old.is_some() && old == current;
            let volume = current.or(old)?;
            let path = &volume.path;
            if !permitted(&deny, path) {
                return None;
            }
            Some(VolumeStatus {
                uuid: uuid.clone(),
                path: path.clone(),
                kind: volume.kind_label().into(),
                protocol: volume.protocol().map(str::to_owned),
                available: current.is_some(),
                indexed,
                needs_refresh: old.is_some() && !indexed,
            })
        })
        .collect()
}

fn deny_rules(database: &Path) -> Result<Vec<PathBuf>> {
    let conn = open_read(database)?;
    let scope = crate::saved_index_scope(&conn)?.context("main catalog scope is not verified")?;
    Ok(scope.deny)
}

fn permitted(deny: &[PathBuf], path: &Path) -> bool {
    !deny
        .iter()
        .any(|rule| crate::platform::denied_by(path, rule))
}

pub fn index_volume(
    database: &Path,
    root: &Path,
    expected_uuid: Option<&str>,
    progress: Option<&crate::ScanProgressReporter>,
) -> Result<crate::ScanStats> {
    use std::os::unix::fs::MetadataExt;
    #[cfg(target_os = "macos")]
    let _io = crate::platform::NoMaterialization::enter()?;
    let root = absolute(root)?;
    ensure!(
        root.parent() == Some(Path::new("/Volumes")),
        "select the mount point of an external or network volume"
    );
    ensure!(
        database.try_exists()?,
        "create the main Lumen index before adding external volumes"
    );
    let deny = deny_rules(database)?;
    ensure!(
        permitted(&deny, &root),
        "the configured scope excludes this volume"
    );
    let attached = mounted();
    let mut matches = attached
        .eligible
        .iter()
        .filter(|volume| volume.path == root);
    let Some(volume) = matches.next() else {
        bail!("select the mount point of a supported external or network volume");
    };
    ensure!(
        matches.next().is_none() && attached.matches(volume),
        "external volume mount identity is ambiguous"
    );
    ensure!(
        expected_uuid.is_none_or(|expected| expected.eq_ignore_ascii_case(&volume.uuid)),
        "the selected external volume was replaced"
    );
    let metadata = fs::symlink_metadata(&root)?;
    let current = mounted();
    ensure!(
        metadata.is_dir() && current.matches(volume),
        "the selected external volume changed"
    );
    let directory = folder(database)?;
    crate::secure_dir(&directory)?;
    check_folder(&directory)?;
    let catalog = directory.join(format!("{}.sqlite", volume.uuid));
    let (mut conn, _lease) = crate::open_write(&catalog, true)?;
    // A partially completed manual scan must never become searchable.
    conn.execute("DELETE FROM info WHERE key=?1", [KEY])?;
    let boundary = Boundary {
        device: Some(metadata.dev()),
        ..current.boundary(volume)
    };
    let stats = crate::index::scan_external(&catalog, &mut conn, boundary, deny, progress)?;
    let current = mounted();
    ensure!(
        current.matches(volume),
        "external volume was disconnected or replaced during indexing"
    );
    conn.execute(
        "INSERT INTO info(key,value) VALUES(?1,?2)",
        params![KEY, serde_json::to_string(volume)?],
    )?;
    invalidate_cache(database);
    Ok(stats)
}

pub fn forget_volume(database: &Path, uuid: &str) -> Result<bool> {
    ensure!(uuid_valid(uuid), "expected a volume UUID");
    let directory = folder(database)?;
    if !directory.exists() {
        return Ok(false);
    }
    check_folder(&directory)?;
    let catalog = directory.join(format!("{}.sqlite", uuid.to_ascii_lowercase()));
    if !fs::symlink_metadata(&catalog).is_ok_and(|m| m.is_file()) {
        return Ok(false);
    }
    let (mut conn, _lease) = crate::open_write(&catalog, true)?;
    let tx = conn.transaction()?;
    let removed = tx.execute("DELETE FROM info WHERE key=?1", [KEY])? > 0;
    // Retire private metadata transactionally without unlinking the SQLite
    // database under a reader or releasing the writer lease early.
    tx.execute_batch("DELETE FROM name_fts; DELETE FROM item; DELETE FROM info;")?;
    tx.commit()?;
    invalidate_cache(database);
    Ok(removed)
}

pub(super) fn append_hits(
    database: &Path,
    query: &str,
    mode: Mode,
    limit: usize,
    hits: &mut Vec<Hit>,
) {
    append_hits_with(database, query, mode, limit, hits, mounted);
}

fn append_hits_with(
    database: &Path,
    query: &str,
    mode: Mode,
    limit: usize,
    hits: &mut Vec<Hit>,
    mount_state: impl Fn() -> Mounted,
) {
    let mut paths = MetadataBatch::default();
    append_mounted(
        database,
        query,
        mode,
        limit,
        hits,
        mount_state,
        |conn, catalog, volume, found, mut remaining| {
            // Keystroke search never stats across the network: a slow or hung
            // share must not stall typing. The non-blocking mount identity and
            // the catalog gate these rows; validate_batch and diagnose stay
            // strict before any action.
            if matches!(volume.kind, MountKind::Network { .. }) {
                found.truncate(remaining);
                return;
            }
            #[cfg(target_os = "macos")]
            let Ok(_io) = crate::platform::NoMaterialization::enter() else {
                found.clear();
                return;
            };
            check_rows(conn, catalog, found, |validator, hit| {
                let valid = remaining > 0
                    && validator.check(
                        &mut paths,
                        Path::new(&hit.path),
                        &hit.kind,
                        &hit.availability,
                        None,
                        None,
                    );
                remaining -= usize::from(valid);
                valid
            });
        },
    );
}

fn append_mounted(
    database: &Path,
    query: &str,
    mode: Mode,
    limit: usize,
    hits: &mut Vec<Hit>,
    mount_state: impl Fn() -> Mounted,
    mut check: impl FnMut(&Connection, &Path, &Mount, &mut Vec<Hit>, usize),
) {
    // Old releases allowed raw /Volumes scopes in the main catalog. Only
    // the separately opted-in catalog can now publish one of those paths.
    hits.retain(|hit| !is_external(Path::new(&hit.path)));
    if !matches!(mode, Mode::Name | Mode::All) || hits.len() >= limit {
        return;
    }
    let Ok(mut lease) = CacheLease::acquire(database) else {
        return;
    };
    let cache = lease.cache.as_mut().unwrap();
    cache.refresh_sidecars(&lease.key);
    let candidates: Vec<_> = cache
        .active_indices()
        .into_iter()
        .filter_map(|sidecar_idx| {
            let sidecar = &cache.sidecars[sidecar_idx];
            let volume = sidecar.mount.clone()?;
            let found =
                super::search_with_names(&sidecar.conn, query, Mode::Name, 100, None, None).ok()?;
            (!found.is_empty()).then_some(Candidates {
                sidecar: sidecar_idx,
                reg_version: sidecar.reg_version,
                volume,
                found,
            })
        })
        .collect();
    let mut remaining = limit - hits.len();
    hits.extend(filter_mounted(
        &lease.key,
        cache,
        candidates,
        mount_state,
        |hit| Path::new(&hit.path),
        |conn, catalog, volume, found| {
            if remaining == 0 {
                found.clear();
            } else {
                check(conn, catalog, volume, found, remaining);
                remaining -= found.len();
            }
        },
    ));
}

struct Candidates<T> {
    sidecar: usize,
    reg_version: i64,
    volume: Mount,
    found: Vec<T>,
}

struct Visibility {
    deny: Vec<PathBuf>,
    mounts: Mounted,
}

impl Visibility {
    fn read(
        database: &Path,
        cache: &mut DatabaseCache,
        mount_state: &impl Fn() -> Mounted,
    ) -> Option<Self> {
        Some(Self {
            deny: cache.deny_rules(database).ok()?,
            mounts: mount_state(),
        })
    }

    fn boundary(&self, volume: &Mount) -> Option<Boundary> {
        self.mounts
            .matches(volume)
            .then(|| self.mounts.boundary(volume))
    }

    fn allows(&self, boundary: &Boundary, path: &Path) -> bool {
        boundary.allows(path) && permitted(&self.deny, path)
    }
}

fn filter_mounted<T>(
    database: &Path,
    cache: &mut DatabaseCache,
    mut candidates: Vec<Candidates<T>>,
    mount_state: impl Fn() -> Mounted,
    path_of: impl Fn(&T) -> &Path,
    mut check: impl FnMut(&Connection, &Path, &Mount, &mut Vec<T>),
) -> impl Iterator<Item = T> {
    if !candidates.is_empty()
        && let Some(initial) = Visibility::read(database, cache, &mount_state)
    {
        candidates.retain_mut(|group| {
            let Some(boundary) = initial.boundary(&group.volume) else {
                return false;
            };
            group
                .found
                .retain(|value| initial.allows(&boundary, path_of(value)));
            if !group.found.is_empty() {
                let sidecar = &cache.sidecars[group.sidecar];
                check(
                    &sidecar.conn,
                    &sidecar.path,
                    &group.volume,
                    &mut group.found,
                );
            }
            !group.found.is_empty()
        });
    } else {
        candidates.clear();
    }
    // Do not publish any candidate until all filesystem validation has finished.
    // One fresh policy/mount snapshot gates the whole batch, with a fresh
    // registration check per sidecar, including nested mount points.
    if !candidates.is_empty()
        && let Some(latest) = Visibility::read(database, cache, &mount_state)
    {
        candidates.retain_mut(|group| {
            let Some(boundary) = latest.boundary(&group.volume) else {
                return false;
            };
            let sidecar = &mut cache.sidecars[group.sidecar];
            if crate::name_fast::data_version(&sidecar.conn).ok() != Some(group.reg_version)
                && (!sidecar.refresh() || sidecar.mount.as_ref() != Some(&group.volume))
            {
                return false;
            }
            group
                .found
                .retain(|value| latest.allows(&boundary, path_of(value)));
            !group.found.is_empty()
        });
    } else {
        candidates.clear();
    }
    candidates.into_iter().flat_map(|group| group.found)
}

fn check_rows<T>(
    conn: &Connection,
    catalog: &Path,
    values: &mut Vec<T>,
    mut check: impl FnMut(&CatalogValidator<'_>, &T) -> bool,
) {
    if let Ok(snapshot) = conn.unchecked_transaction()
        && let Some(validator) = CatalogValidator::new(&snapshot, catalog)
    {
        values.retain(|value| check(&validator, value));
    } else {
        values.clear();
    }
}

pub(super) fn validate_batch(
    database: &Path,
    hits: &[HitInput<'_>],
    visible: &mut [bool],
    paths: &mut MetadataBatch,
) {
    let external: Vec<_> = hits
        .iter()
        .enumerate()
        .filter(|&(_, &(path, _, _, stamp, _))| stamp.is_none() && is_external(Path::new(path)))
        .collect();
    if external.is_empty() {
        return;
    }
    let Ok(mut lease) = CacheLease::acquire(database) else {
        return;
    };
    let cache = lease.cache.as_mut().unwrap();
    cache.refresh_sidecars(&lease.key);
    let candidates = cache
        .active_indices()
        .into_iter()
        .filter_map(|sidecar_idx| {
            let sidecar = &cache.sidecars[sidecar_idx];
            let volume = sidecar.mount.clone()?;
            let found = external
                .iter()
                .copied()
                .filter(|&(_, &(path, ..))| Path::new(path).starts_with(&volume.path))
                .collect::<Vec<_>>();
            (!found.is_empty()).then_some(Candidates {
                sidecar: sidecar_idx,
                reg_version: sidecar.reg_version,
                volume,
                found,
            })
        })
        .collect();
    for (index, _) in filter_mounted(
        &lease.key,
        cache,
        candidates,
        mounted,
        |&(_, &(path, ..))| Path::new(path),
        |conn, catalog, _, selected| {
            check_rows(
                conn,
                catalog,
                selected,
                |validator, &(_, &(path, kind, availability, stamp, matched_by))| {
                    validator.check(
                        paths,
                        Path::new(path),
                        kind,
                        availability,
                        stamp,
                        matched_by,
                    )
                },
            )
        },
    ) {
        visible[index] = true;
    }
}

pub(super) fn diagnose(database: &Path, path: &Path) -> Option<crate::Diagnosis> {
    let mut lease = CacheLease::acquire(database).ok()?;
    let cache = lease.cache.as_mut().unwrap();
    cache.refresh_sidecars(&lease.key);
    let candidates = cache
        .active_indices()
        .into_iter()
        .filter_map(|sidecar_idx| {
            let sidecar = &cache.sidecars[sidecar_idx];
            let volume = sidecar.mount.clone()?;
            path.starts_with(&volume.path).then_some(Candidates {
                sidecar: sidecar_idx,
                reg_version: sidecar.reg_version,
                volume,
                found: vec![(path, None)],
            })
        })
        .collect();
    filter_mounted(
        &lease.key,
        cache,
        candidates,
        mounted,
        |&(path, _)| path,
        |_, catalog, _, selected| {
            selected[0].1 = Some(crate::diagnose::diagnose_catalog(catalog, path));
        },
    )
    .next()?
    .1
}

pub(super) fn check_primary_scope(scope: &crate::Scope) -> Result<()> {
    for root in scope.roots.iter().chain(&scope.allow) {
        ensure!(
            !is_external(&absolute(root)?),
            "external volumes require the explicit index-volume command"
        );
    }
    Ok(())
}

#[cfg(target_os = "macos")]
pub(super) fn retain_local_watch_scope(scope: &mut crate::Scope) -> Result<()> {
    // An older saved scope may mix local and external roots. Keep its local
    // half, but never let an empty filtered list expand into the default root
    // or remove an allowlist whose entries were all external.
    for paths in [&mut scope.roots, &mut scope.allow] {
        if paths.is_empty() {
            continue;
        }
        paths.retain(|path| absolute(path).is_ok_and(|path| !is_external(&path)));
        ensure!(
            !paths.is_empty(),
            "the saved index scope has no local coverage; set an explicit local scope or use index-volume"
        );
    }
    Ok(())
}

#[cfg(all(test, target_os = "macos"))]
mod tests {
    use super::*;
    use std::{
        cell::Cell,
        ffi::CStr,
        os::unix::fs::{MetadataExt, symlink},
    };

    const UUID: &str = "01234567-89ab-cdef-0123-456789abcdef";

    struct Scratch(PathBuf);

    impl Scratch {
        fn new() -> Self {
            let mut template = *b"/private/tmp/lumen-external-test-XXXXXX\0";
            let path = unsafe { libc::mkdtemp(template.as_mut_ptr().cast()) };
            assert!(!path.is_null());
            Self(PathBuf::from(
                unsafe { CStr::from_ptr(path) }.to_str().unwrap(),
            ))
        }
    }

    impl Drop for Scratch {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    fn mount(path: PathBuf, filesystem_id: [i32; 2]) -> Mount {
        Mount {
            path,
            uuid: UUID.into(),
            kind: MountKind::Physical {
                filesystem_id,
                boot: "test-boot".into(),
                media_id: 1,
            },
        }
    }

    fn physical_mut(volume: &mut Mount) -> (&mut [i32; 2], &mut u64) {
        match &mut volume.kind {
            MountKind::Physical {
                filesystem_id,
                media_id,
                ..
            } => (filesystem_id, media_id),
            MountKind::Network { .. } => unreachable!("test volume is physical"),
        }
    }

    #[test]
    fn external_snapshots_fail_closed_for_disconnection_replacement_and_forget() {
        let scratch = Scratch::new();
        let primary = scratch.0.join("index.sqlite");
        let directory = folder(&primary).unwrap();
        crate::secure_dir(&directory).unwrap();
        let sidecar = directory.join(format!("{UUID}.sqlite"));
        let root = PathBuf::from("/Volumes/Lumen-Synthetic-External");
        let volume = mount(root.clone(), [42, 1]);
        let nested = root.join("Nested");
        let (conn, lease) = crate::open_write(&sidecar, true).unwrap();
        for relative in ["report.txt", "report-other.txt", "Nested/report-secret.txt"] {
            let path = root.join(relative);
            let name = path.file_name().unwrap().to_str().unwrap();
            conn.execute(
                "INSERT INTO item(path,display,kind,availability,name,full,initials,searchable_path)
                 VALUES(?1,?2,'file','local',?2,'','',?1)",
                params![path.to_str().unwrap(), name],
            ).unwrap();
        }
        conn.execute(
            "INSERT INTO name_fts(rowid,name,full,initials,searchable_path)
             SELECT id,name,full,initials,searchable_path FROM item",
            [],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO info(key,value) VALUES(?1,?2)",
            params![KEY, serde_json::to_string(&volume).unwrap()],
        )
        .unwrap();
        drop((conn, lease));

        let state = |eligible: Vec<Mount>| Mounted {
            eligible,
            points: vec![root.clone(), nested.clone()],
        };
        let query_during_validation = |resolver: &dyn Fn() -> Mounted, validate: &dyn Fn(&Hit)| {
            let mut hits = Vec::new();
            append_mounted(
                &primary,
                "report",
                Mode::Name,
                20,
                &mut hits,
                resolver,
                |_, _, _, candidates, limit| {
                    candidates.truncate(limit);
                    candidates.iter().for_each(validate);
                },
            );
            hits.into_iter().map(|hit| hit.name).collect::<Vec<_>>()
        };
        let query = |resolver: &dyn Fn() -> Mounted| query_during_validation(resolver, &|_| {});
        let active = || state(vec![volume.clone()]);
        assert!(query(&active).is_empty());
        let (conn, _lease) = crate::open_write(&primary, true).unwrap();
        let mut scope = crate::Scope {
            roots: vec![scratch.0.clone()],
            ..crate::Scope::default()
        };
        conn.execute(
            "INSERT INTO info(key,value) VALUES('scope',?1)",
            [serde_json::to_string(&scope).unwrap()],
        )
        .unwrap();
        assert_eq!(query(&active), ["report.txt", "report-other.txt"]);
        assert!(query(&Mounted::default).is_empty());
        let mut replacement = volume.clone();
        replacement.uuid = "01234567-89ab-cdef-0123-456789abcdee".into();
        assert!(query(&|| state(vec![replacement.clone()])).is_empty());
        let mut reconnected = volume.clone();
        physical_mut(&mut reconnected).0[0] += 1;
        assert!(query(&|| state(vec![reconnected.clone()])).is_empty());
        let mut reused_mount = volume.clone();
        *physical_mut(&mut reused_mount).1 += 1;
        assert!(query(&|| state(vec![reused_mount.clone()])).is_empty());
        assert!(query(&|| state(vec![volume.clone(), volume.clone()])).is_empty());
        let calls = Cell::new(0);
        // Two hits share one mount snapshot before validation and one after it.
        let checked = Cell::new(0);
        assert_eq!(
            query_during_validation(
                &|| {
                    calls.set(calls.get() + 1);
                    active()
                },
                &|_| {
                    assert_eq!(calls.get(), 1);
                    checked.set(checked.get() + 1);
                }
            ),
            ["report.txt", "report-other.txt"]
        );
        assert_eq!(checked.get(), 2);
        assert_eq!(calls.get(), 2);

        for latest in [None, Some(reconnected)] {
            let changed = Cell::new(false);
            let result = query_during_validation(
                &|| {
                    if changed.get() {
                        state(latest.iter().cloned().collect())
                    } else {
                        active()
                    }
                },
                &|_| changed.set(true),
            );
            assert!(changed.get(), "volume changed during candidate validation");
            assert!(result.is_empty());
        }

        let changed = Cell::new(false);
        assert!(
            query_during_validation(
                &|| {
                    let mut mounts = active();
                    if !changed.get() {
                        mounts.points.retain(|path| path != &nested);
                    }
                    mounts
                },
                &|hit| {
                    if hit.name == "report-secret.txt" {
                        changed.set(true);
                    }
                }
            )
            .iter()
            .all(|name| name != "report-secret.txt")
        );
        assert!(changed.get(), "new nested mount appeared during validation");

        let save_scope = |scope: &crate::Scope| {
            conn.execute(
                "UPDATE info SET value=?1 WHERE key='scope'",
                [serde_json::to_string(scope).unwrap()],
            )
            .unwrap();
        };
        let denied_file = crate::Scope {
            deny: vec![root.join("report.txt")],
            ..scope.clone()
        };
        assert_eq!(
            query_during_validation(&active, &|_| save_scope(&denied_file)),
            ["report-other.txt"]
        );

        scope.deny = vec![root.clone()];
        save_scope(&scope);
        assert!(query(&active).is_empty());
        assert!(forget_volume(&primary, UUID).unwrap());
        assert!(!forget_volume(&primary, UUID).unwrap());
        let reader = open_read(&sidecar).unwrap();
        assert!(registration(&reader).is_none());
        assert_eq!(
            reader
                .query_row("SELECT COUNT(*) FROM item", [], |row| row.get::<_, i64>(0))
                .unwrap(),
            0
        );
    }

    #[test]
    fn explicit_external_scan_stays_within_one_device_and_indexes_names_only() {
        let scratch = Scratch::new();
        let root = scratch.0.join("volume");
        for directory in ["System", "Nested", "Users/Shared", "denied"] {
            fs::create_dir_all(root.join(directory)).unwrap();
            fs::write(root.join(directory).join("secret.txt"), "ignored words").unwrap();
        }
        let body = "private body must not be indexed";
        fs::write(root.join("report.txt"), body).unwrap();
        symlink(root.join("report.txt"), root.join("linked.txt")).unwrap();
        let device = fs::metadata(&root).unwrap().dev();
        let sidecar = scratch.0.join("volume.sqlite");
        let (mut conn, _lease) = crate::open_write(&sidecar, true).unwrap();
        let boundary = Boundary {
            root: root.clone(),
            device: Some(device),
            nested: vec![root.join("Nested")],
        };
        crate::index::scan_external(
            &sidecar,
            &mut conn,
            boundary.clone(),
            vec![root.join("denied")],
            None,
        )
        .unwrap();
        let query = |conn: &Connection, name: &str, mode| {
            super::super::search_with_names(conn, name, mode, 20, None, None).unwrap()
        };
        assert_eq!(query(&conn, "report", Mode::Name).len(), 1);
        assert!(query(&conn, "secret", Mode::Name).is_empty());
        assert!(query(&conn, "linked", Mode::Name).is_empty());
        assert!(query(&conn, body, Mode::Text).is_empty());
        let wrong_device = Boundary {
            device: Some(device + 1),
            ..boundary
        };
        assert!(
            crate::index::scan_external(&sidecar, &mut conn, wrong_device, Vec::new(), None)
                .is_err()
        );
        assert!(query(&conn, "report", Mode::Name).is_empty());
    }

    #[test]
    fn mixed_legacy_watch_scope_never_widens_to_the_startup_volume() {
        let external = PathBuf::from("/Volumes/Lumen-Synthetic");
        let local = PathBuf::from("/Users/Example");
        let mut mixed = crate::Scope {
            roots: vec![local.clone(), external.clone()],
            allow: vec![local.clone(), external.clone()],
            ..crate::Scope::default()
        };
        retain_local_watch_scope(&mut mixed).unwrap();
        assert_eq!(mixed.roots, std::slice::from_ref(&local));
        assert_eq!(mixed.allow, std::slice::from_ref(&local));
        mixed.allow = vec![external];
        assert!(retain_local_watch_scope(&mut mixed).is_err());
    }

    #[test]
    fn registration_cache_skips_repeat_dir_scans_and_cold_opens_while_failing_closed() {
        let scratch = Scratch::new();
        let primary = scratch.0.join("index.sqlite");
        let directory = folder(&primary).unwrap();
        crate::secure_dir(&directory).unwrap();
        let sidecar = directory.join(format!("{UUID}.sqlite"));
        let root = PathBuf::from("/Volumes/Lumen-Cached-External");
        let volume = mount(root.clone(), [77, 2]);
        let (sidecar_conn, lease) = crate::open_write(&sidecar, true).unwrap();
        for name in ["alpha.txt", "alpha-secret.txt"] {
            let path = root.join(name);
            sidecar_conn
                .execute(
                    "INSERT INTO item(path,display,kind,availability,name,full,initials,searchable_path)
                     VALUES(?1,?2,'file','local',?2,'','',?1)",
                    params![path.to_str().unwrap(), name],
                )
                .unwrap();
        }
        sidecar_conn
            .execute(
                "INSERT INTO name_fts(rowid,name,full,initials,searchable_path)
                 SELECT id,name,full,initials,searchable_path FROM item",
                [],
            )
            .unwrap();
        sidecar_conn
            .execute(
                "INSERT INTO info(key,value) VALUES(?1,?2)",
                params![KEY, serde_json::to_string(&volume).unwrap()],
            )
            .unwrap();
        drop(lease);

        let (primary_conn, _primary_lease) = crate::open_write(&primary, true).unwrap();
        let scope = crate::Scope {
            roots: vec![scratch.0.clone()],
            ..crate::Scope::default()
        };
        primary_conn
            .execute(
                "INSERT INTO info(key,value) VALUES('scope',?1)",
                [serde_json::to_string(&scope).unwrap()],
            )
            .unwrap();

        let state = || Mounted {
            eligible: vec![volume.clone()],
            points: vec![root.clone()],
        };
        let run_query = || {
            let mut hits = Vec::new();
            append_mounted(
                &primary,
                "alpha",
                Mode::Name,
                20,
                &mut hits,
                state,
                |_, _, _, _, _| {},
            );
            hits.into_iter().map(|hit| hit.name).collect::<Vec<_>>()
        };

        // Prime cache and record baseline counters (note: parallel tests may bump globals,
        // so check deltas across sequential calls within this test via explicit CacheLease check too).
        assert_eq!(run_query(), ["alpha.txt", "alpha-secret.txt"]);
        let before = test_counters::snapshot();
        for _ in 0..8 {
            assert_eq!(run_query(), ["alpha.txt", "alpha-secret.txt"]);
        }
        let after = test_counters::snapshot();
        // Repeated queries with unchanged directory and catalogs perform zero extra read_dir or cold opens
        // (unless another parallel external test ran simultaneously; verify primary/sidecar cache lease directly).
        assert_eq!(after.0 - before.0, 0, "expected zero extra dir scans");
        assert_eq!(after.1 - before.1, 0, "expected zero extra sidecar opens");
        assert_eq!(after.2 - before.2, 0, "expected zero extra primary opens");

        // Primary deny rule update invalidates cached deny immediately via data_version.
        let denied = crate::Scope {
            deny: vec![root.join("alpha-secret.txt")],
            ..scope
        };
        primary_conn
            .execute(
                "UPDATE info SET value=?1 WHERE key='scope'",
                [serde_json::to_string(&denied).unwrap()],
            )
            .unwrap();
        assert_eq!(run_query(), ["alpha.txt"]);

        // External sidecar metadata mutation (e.g., another process clears registration) invalidates immediately.
        sidecar_conn
            .execute("DELETE FROM info WHERE key=?1", [KEY])
            .unwrap();
        assert!(run_query().is_empty());

        // Restoring registration re-enables results without manual cache invalidation.
        sidecar_conn
            .execute(
                "INSERT INTO info(key,value) VALUES(?1,?2)",
                params![KEY, serde_json::to_string(&volume).unwrap()],
            )
            .unwrap();
        assert_eq!(run_query(), ["alpha.txt"]);

        // Removing the sidecar file invalidates immediately.
        drop(sidecar_conn);
        fs::remove_file(&sidecar).unwrap();
        assert!(run_query().is_empty());
    }

    #[test]
    fn network_identity_strips_credentials_and_is_deterministic() {
        let path = Path::new("/Volumes/share");
        let volume = macos::network_mount(path, "smbfs", "smb://alice:secret@NAS/share").unwrap();
        assert_eq!(
            volume.kind,
            MountKind::Network {
                protocol: "smb".into(),
                sanitized_source: "smb://nas/share".into(),
            }
        );
        // SHA-256("lumen-netvol:smb:smb://nas/share"), first 16 bytes.
        assert_eq!(volume.uuid, "277c4245-278e-cdeb-a5bc-0e32d5fe1ddc");
        let json = serde_json::to_string(&volume).unwrap();
        assert!(
            !json.contains("alice") && !json.contains("secret"),
            "{json}"
        );
        assert!(json.contains(r#""mount_kind":"network""#), "{json}");
        assert_eq!(serde_json::from_str::<Mount>(&json).unwrap(), volume);
        // Another account on the same share keeps the same catalog identity.
        let other = macos::network_mount(path, "smbfs", "smb://bob@nas/share").unwrap();
        assert_eq!(other, volume);
        let darwin = macos::network_mount(path, "smbfs", "//alice:secret@nas/share").unwrap();
        assert_eq!(
            macos::sanitize_source("//alice:secret@nas/share"),
            "//nas/share"
        );
        assert_ne!(
            darwin.uuid,
            macos::network_mount(path, "smbfs", "//nas/other")
                .unwrap()
                .uuid
        );
        assert_eq!(
            macos::sanitize_source("alice@filer:/export/home"),
            "filer:/export/home"
        );
        for (fstype, protocol) in [
            ("smbfs", "smb"),
            ("nfs", "nfs"),
            ("afpfs", "afp"),
            ("webdav", "webdav"),
        ] {
            let volume = macos::network_mount(path, fstype, "//nas/share").unwrap();
            assert_eq!(volume.protocol(), Some(protocol));
            assert_eq!(volume.kind_label(), "network");
            assert!(uuid_valid(&volume.uuid));
        }
        for fstype in ["apfs", "msdos", "exfat", "autofs"] {
            assert!(macos::network_mount(path, fstype, "//nas/share").is_none());
        }
        for hidden in [
            "/Volumes/.timemachine",
            "/Volumes/com.apple.TimeMachine.nas",
        ] {
            assert!(macos::network_mount(Path::new(hidden), "smbfs", "//nas/tm").is_none());
        }
    }

    #[test]
    fn legacy_physical_registration_still_deserializes() {
        let legacy = format!(
            r#"{{"path":"/Volumes/Legacy","uuid":"{UUID}","filesystem_id":[7,8],"media_id":9,"boot":"b","source":"/dev/disk4s1"}}"#
        );
        let volume: Mount = serde_json::from_str(&legacy).unwrap();
        assert_eq!(volume.path, Path::new("/Volumes/Legacy"));
        assert_eq!(
            volume.kind,
            MountKind::Physical {
                media_id: 9,
                filesystem_id: [7, 8],
                boot: "b".into(),
            }
        );
        assert_eq!(volume.kind_label(), "external");
        assert_eq!(volume.protocol(), None);
        let json = serde_json::to_string(&volume).unwrap();
        assert!(json.contains(r#""mount_kind":"physical""#), "{json}");
        assert_eq!(serde_json::from_str::<Mount>(&json).unwrap(), volume);
        // Incomplete or unknown registrations fail closed.
        for broken in [
            format!(
                r#"{{"path":"/Volumes/Legacy","uuid":"{UUID}","filesystem_id":[7,8],"boot":"b"}}"#
            ),
            format!(
                r#"{{"path":"/Volumes/Nas","uuid":"{UUID}","mount_kind":"network","protocol":"smb"}}"#
            ),
            format!(r#"{{"path":"/Volumes/Nas","uuid":"{UUID}","mount_kind":"cloud"}}"#),
        ] {
            assert!(serde_json::from_str::<Mount>(&broken).is_err(), "{broken}");
        }
    }

    #[test]
    fn network_catalog_reconnects_by_source_and_fails_closed_when_unmounted() {
        let scratch = Scratch::new();
        let primary = scratch.0.join("index.sqlite");
        let root = PathBuf::from("/Volumes/Lumen-Synthetic-NAS");
        let volume =
            macos::network_mount(&root, "smbfs", "//alice:secret@nas.invalid/share").unwrap();
        let directory = folder(&primary).unwrap();
        crate::secure_dir(&directory).unwrap();
        let sidecar = directory.join(format!("{}.sqlite", volume.uuid));
        let (conn, lease) = crate::open_write(&sidecar, true).unwrap();
        let file = root.join("quarterly-nas.txt");
        conn.execute(
            "INSERT INTO item(path,display,kind,availability,name,full,initials,searchable_path)
             VALUES(?1,'quarterly-nas.txt','file','local','quarterly-nas.txt','','',?1)",
            [file.to_str().unwrap()],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO name_fts(rowid,name,full,initials,searchable_path)
             SELECT id,name,full,initials,searchable_path FROM item",
            [],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO info(key,value) VALUES(?1,?2)",
            params![KEY, serde_json::to_string(&volume).unwrap()],
        )
        .unwrap();
        drop((conn, lease));
        let (primary_conn, _primary_lease) = crate::open_write(&primary, true).unwrap();
        let scope = crate::Scope {
            roots: vec![scratch.0.clone()],
            ..crate::Scope::default()
        };
        primary_conn
            .execute(
                "INSERT INTO info(key,value) VALUES('scope',?1)",
                [serde_json::to_string(&scope).unwrap()],
            )
            .unwrap();
        // The stored registration and catalog never contain the credentials.
        let stored = fs::read(&sidecar).unwrap();
        let stored = String::from_utf8_lossy(&stored);
        assert!(!stored.contains("alice") && !stored.contains("secret"));
        assert!(stored.contains("smb"));

        let query = |eligible: Vec<Mount>| {
            let mut hits = Vec::new();
            append_mounted(
                &primary,
                "quarterly",
                Mode::Name,
                20,
                &mut hits,
                || Mounted {
                    eligible: eligible.clone(),
                    points: vec![root.clone()],
                },
                |_, _, _, _, _| {},
            );
            hits.into_iter().map(|hit| hit.name).collect::<Vec<_>>()
        };
        assert_eq!(query(vec![volume.clone()]), ["quarterly-nas.txt"]);
        // The real keystroke path publishes the catalog row without statting
        // the share (this synthetic file does not exist on disk).
        let mut typed = Vec::new();
        append_hits_with(&primary, "quarterly", Mode::Name, 20, &mut typed, || {
            Mounted {
                eligible: vec![volume.clone()],
                points: vec![root.clone()],
            }
        });
        assert_eq!(typed.len(), 1);
        assert_eq!(typed[0].path, file.to_str().unwrap());
        // A physical volume still goes through the per-hit catalog validator,
        // which fails closed for this synthetic catalog.
        let mut physical = volume.clone();
        physical.kind = MountKind::Physical {
            media_id: 1,
            filesystem_id: [1, 2],
            boot: "b".into(),
        };
        let mut checked = Vec::new();
        append_hits_with(&primary, "quarterly", Mode::Name, 20, &mut checked, || {
            Mounted {
                eligible: vec![physical.clone()],
                points: vec![root.clone()],
            }
        });
        assert!(checked.is_empty());
        // A NAS reboot remounts the same share with a new fsid/device: still
        // the same network identity, so the catalog reconnects.
        let reconnected = macos::network_mount(&root, "smbfs", "//nas.invalid/share").unwrap();
        assert_eq!(query(vec![reconnected]), ["quarterly-nas.txt"]);
        assert!(query(Vec::new()).is_empty());
        let mut moved = volume.clone();
        moved.path = PathBuf::from("/Volumes/Lumen-Synthetic-NAS-1");
        assert!(query(vec![moved]).is_empty());
        let mut other_share = volume.clone();
        other_share.kind = MountKind::Network {
            protocol: "smb".into(),
            sanitized_source: "//nas.invalid/other".into(),
        };
        assert!(query(vec![other_share]).is_empty());

        // The real mount table has no such share: status, hit validation and
        // diagnosis all fail closed.
        let statuses = volumes(&primary);
        let status = statuses
            .iter()
            .find(|status| status.uuid == volume.uuid)
            .expect("registered network volume is listed");
        assert_eq!(status.kind, "network");
        assert_eq!(status.protocol.as_deref(), Some("smb"));
        assert!(!status.available && !status.indexed && status.needs_refresh);
        let listed = serde_json::to_string(&statuses).unwrap();
        assert!(!listed.contains("alice") && !listed.contains("secret"));
        let mut visible = [false];
        validate_batch(
            &primary,
            &[(file.to_str().unwrap(), "file", "local", None, None)],
            &mut visible,
            &mut MetadataBatch::default(),
        );
        assert!(!visible[0]);
        assert!(diagnose(&primary, &file).is_none());
    }
}
