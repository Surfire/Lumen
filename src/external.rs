use crate::{Hit, Mode, Result, absolute, open_read, with_suffix};
use anyhow::{Context, bail, ensure};
use rusqlite::{Connection, params};
use serde::{Deserialize, Serialize};
use std::{
    collections::HashSet,
    fs,
    path::{Path, PathBuf},
};

#[cfg(target_os = "macos")]
mod macos;

const KEY: &str = "external_volume";

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub(super) struct Mount {
    pub(super) path: PathBuf,
    uuid: String,
    filesystem_id: [i32; 2],
    media_id: u64,
    boot: String,
    source: String,
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

fn check_folder(path: &Path) -> Result<()> {
    use std::os::unix::fs::{MetadataExt, PermissionsExt};
    let meta = fs::symlink_metadata(path)?;
    ensure!(
        meta.is_dir()
            && meta.uid() == unsafe { libc::geteuid() }
            && meta.permissions().mode() & 0o077 == 0,
        "external volume catalog must be in a user-only directory"
    );
    Ok(())
}

fn catalogs(database: &Path) -> Vec<PathBuf> {
    let Ok(folder) = folder(database) else {
        return Vec::new();
    };
    if check_folder(&folder).is_err() {
        return Vec::new();
    }
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

#[derive(Serialize)]
pub struct VolumeStatus {
    uuid: String,
    path: PathBuf,
    /// An eligible physical volume is mounted here now.
    available: bool,
    /// A valid catalog is bound to this mount instance.
    indexed: bool,
    /// An older snapshot exists and needs an explicit refresh.
    needs_refresh: bool,
}

pub fn volumes(database: &Path) -> Vec<VolumeStatus> {
    let (deny, registered) = match deny_rules(database) {
        Ok(deny) => (
            deny,
            registrations(database)
                .into_iter()
                .map(|(_, _, volume)| volume)
                .collect::<Vec<_>>(),
        ),
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
            let path = &current.or(old)?.path;
            if !permitted(&deny, path) {
                return None;
            }
            Some(VolumeStatus {
                uuid: uuid.clone(),
                path: path.clone(),
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
        "select the mount point of a local external volume"
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
        bail!("select the mount point of a supported local external volume");
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
    Ok(removed)
}

fn registrations(database: &Path) -> Vec<(PathBuf, Connection, Mount)> {
    let mut seen = HashSet::new();
    catalogs(database)
        .into_iter()
        .filter_map(|path| {
            let conn = open_read(&path).ok()?;
            let mount = registration(&conn)?;
            (path.file_stem()?.to_str()? == mount.uuid && seen.insert(mount.uuid.clone()))
                .then_some((path, conn, mount))
        })
        .collect()
}

pub(super) fn append_hits(
    database: &Path,
    query: &str,
    mode: Mode,
    limit: usize,
    hits: &mut Vec<Hit>,
) {
    append_mounted(
        database,
        query,
        mode,
        limit,
        hits,
        mounted,
        |catalog, hit| {
            crate::diagnose::validate_catalog_hit(
                catalog,
                Path::new(&hit.path),
                &hit.kind,
                &hit.availability,
                None,
            )
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
    validate_hit: impl Fn(&Path, &Hit) -> bool,
) {
    // Old releases allowed raw /Volumes scopes in the main catalog. Only
    // the separately opted-in catalog can now publish one of those paths.
    hits.retain(|hit| !is_external(Path::new(&hit.path)));
    if !matches!(mode, Mode::Name | Mode::All) || hits.len() >= limit {
        return;
    }
    let registered = registrations(database);
    if registered.is_empty() {
        return;
    }
    let Ok(deny) = deny_rules(database) else {
        return;
    };
    let first = mount_state();
    let mut candidates = Vec::new();
    let mut remaining = limit - hits.len();
    for (catalog, conn, volume) in registered {
        if !first.matches(&volume) {
            continue;
        }
        let Ok(found) = super::search_with_names(&conn, query, Mode::Name, 100, None, None) else {
            continue;
        };
        let boundary = first.boundary(&volume);
        let valid: Vec<_> = found
            .into_iter()
            .filter(|hit| {
                let path = Path::new(&hit.path);
                boundary.allows(path) && permitted(&deny, path) && validate_hit(&catalog, hit)
            })
            .take(remaining)
            .collect();
        if !valid.is_empty() {
            remaining -= valid.len();
            candidates.push((conn, volume, valid));
        }
        if remaining == 0 {
            break;
        }
    }
    if candidates.is_empty() {
        return;
    }
    let Ok(deny) = deny_rules(database) else {
        return;
    };
    let latest = mount_state();
    for (conn, volume, valid) in candidates {
        if latest.matches(&volume) && registration(&conn).as_ref() == Some(&volume) {
            let boundary = latest.boundary(&volume);
            hits.extend(valid.into_iter().filter(|hit| {
                let path = Path::new(&hit.path);
                boundary.allows(path) && permitted(&deny, path)
            }));
        }
    }
}

pub(super) fn validate(
    database: &Path,
    path: &Path,
    kind: &str,
    availability: &str,
    stamp: Option<&str>,
) -> bool {
    if stamp.is_some() {
        return false;
    }
    let registered = registrations(database);
    if registered.is_empty() {
        return false;
    }
    let Ok(deny) = deny_rules(database) else {
        return false;
    };
    if !permitted(&deny, path) {
        return false;
    }
    let attached = mounted();
    registered.iter().any(|(catalog, conn, volume)| {
        if !attached.matches(volume)
            || !attached.boundary(volume).allows(path)
            || !crate::diagnose::validate_catalog_hit(catalog, path, kind, availability, None)
        {
            return false;
        }
        let latest = mounted();
        latest.matches(volume)
            && latest.boundary(volume).allows(path)
            && registration(conn).as_ref() == Some(volume)
            && deny_rules(database).is_ok_and(|deny| permitted(&deny, path))
    })
}

pub(super) fn diagnose(database: &Path, path: &Path) -> Option<crate::Diagnosis> {
    let registered = registrations(database);
    if registered.is_empty() || !permitted(&deny_rules(database).ok()?, path) {
        return None;
    }
    let attached = mounted();
    for (catalog, conn, volume) in registered {
        if !attached.matches(&volume) || !attached.boundary(&volume).allows(path) {
            continue;
        }
        let status = crate::diagnose::diagnose_catalog(&catalog, path);
        let latest = mounted();
        if latest.matches(&volume)
            && latest.boundary(&volume).allows(path)
            && registration(&conn).as_ref() == Some(&volume)
            && deny_rules(database).is_ok_and(|deny| permitted(&deny, path))
        {
            return Some(status);
        }
    }
    None
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
            filesystem_id,
            uuid: UUID.into(),
            boot: "test-boot".into(),
            source: "test-device".into(),
            media_id: 1,
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
        for relative in ["report.txt", "Nested/report-secret.txt"] {
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
        let query = |resolver: &dyn Fn() -> Mounted| {
            let mut hits = Vec::new();
            append_mounted(
                &primary,
                "report",
                Mode::Name,
                20,
                &mut hits,
                resolver,
                |_, _| true,
            );
            hits.into_iter().map(|hit| hit.name).collect::<Vec<_>>()
        };
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
        assert_eq!(query(&active), ["report.txt"]);
        assert!(query(&Mounted::default).is_empty());
        let mut replacement = volume.clone();
        replacement.uuid = "01234567-89ab-cdef-0123-456789abcdee".into();
        assert!(query(&|| state(vec![replacement.clone()])).is_empty());
        let mut reconnected = volume.clone();
        reconnected.filesystem_id[0] += 1;
        assert!(query(&|| state(vec![reconnected.clone()])).is_empty());
        let mut reused_mount = volume.clone();
        reused_mount.media_id += 1;
        assert!(query(&|| state(vec![reused_mount.clone()])).is_empty());
        assert!(query(&|| state(vec![volume.clone(), volume.clone()])).is_empty());
        let calls = Cell::new(0);
        assert!(
            query(&|| {
                calls.set(calls.get() + 1);
                if calls.get() == 1 {
                    active()
                } else {
                    Mounted::default()
                }
            })
            .is_empty()
        );

        scope.deny = vec![root.clone()];
        conn.execute(
            "UPDATE info SET value=?1 WHERE key='scope'",
            [serde_json::to_string(&scope).unwrap()],
        )
        .unwrap();
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
}
