use super::{
    MAX_DOCUMENT, ScanPhase, ScanProgressReporter, ScanStats, Scope, absolute, docx, norm,
    open_write, platform, with_suffix,
};
use anyhow::{Context, Result, bail};
use rusqlite::{Connection, OptionalExtension, Transaction, TransactionBehavior, params};
use std::{
    collections::{HashMap, HashSet},
    fs,
    io::{Read, Write},
    os::unix::{fs::MetadataExt, process::CommandExt},
    path::{Path, PathBuf},
    process::{Command, Stdio},
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

pub(super) struct Coverage {
    pub scope: Scope,
    database: PathBuf,
    sidecars: [PathBuf; 4],
    pdf_stamp: Option<String>,
}

impl Coverage {
    pub fn new(database: PathBuf, scope: &Scope) -> Result<Self> {
        let paths = |p: &[PathBuf]| -> Result<Vec<PathBuf>> {
            p.iter()
                .map(|p| absolute(p).map(|p| platform::filesystem_spelling(&p)))
                .collect()
        };
        let scope = Scope {
            roots: paths(&scope.roots())?,
            allow: paths(&scope.allow)?,
            deny: paths(&scope.deny)?,
            documents: scope.documents,
            pdf_helper: scope.pdf_helper.as_deref().map(absolute).transpose()?,
        };
        let database = platform::filesystem_spelling(&database);
        let sidecars = ["-wal", "-shm", "-journal", "-watch-lock"]
            .map(|suffix| with_suffix(&database, suffix));
        let pdf_stamp = scope.pdf_helper.as_ref().map(|path| {
            let metadata = fs::metadata(path).ok();
            format!("{path:?}:{:?}", metadata.as_ref().map(stamp))
        });
        Ok(Self {
            scope,
            database,
            sidecars,
            pdf_stamp,
        })
    }

    #[cfg(target_os = "macos")]
    pub fn refreshed(&self) -> Result<Self> {
        Self::new(self.database.clone(), &self.scope)
    }

    fn contains(&self, path: &Path) -> bool {
        self.scope.roots.iter().any(|root| path.starts_with(root)) && self.allows(path)
    }

    pub fn allows(&self, path: &Path) -> bool {
        self.scope.allows(path)
            && path != self.database
            && !self.sidecars.iter().any(|sidecar| path == sidecar)
            && !self
                .database
                .parent()
                .is_some_and(|p| p.ends_with("Lumen") && path.starts_with(p))
    }
}

pub fn scan(database: &Path, scope: &Scope) -> Result<ScanStats> {
    scan_with_progress(database, scope, None)
}

pub fn scan_with_progress(
    database: &Path,
    scope: &Scope,
    progress: Option<&ScanProgressReporter>,
) -> Result<ScanStats> {
    #[cfg(target_os = "macos")]
    let _io = platform::NoMaterialization::enter()?;
    let file = absolute(database)?;
    let coverage = Coverage::new(file.clone(), scope)?;
    let (mut conn, _lease) =
        open_write(&file, true).with_context(|| format!("open index {}", file.display()))?;
    restrict_scope(&mut conn, &coverage)?;
    reconcile(&mut conn, &coverage, true, progress)
}

/// Load only the complete scope. Legacy "scan" reports recorded roots but omitted
/// deny rules and document options, so they cannot safely authorize a new scan.
#[cfg(target_os = "macos")]
pub(super) fn startup_scope(conn: &Connection, requested: &Scope) -> Result<Scope> {
    if requested.unspecified() {
        let stored: Option<String> = conn
            .query_row("SELECT value FROM info WHERE key='scope'", [], |r| r.get(0))
            .optional()?;
        if let Some(stored) = stored {
            return serde_json::from_str(&stored).context("read saved watch scope");
        }
        let legacy: bool = conn.query_row(
            "SELECT EXISTS(SELECT 1 FROM info WHERE key='scan')",
            [],
            |r| r.get(0),
        )?;
        if legacy {
            bail!(
                "this index predates saved scope settings; pass the original --root/--allow/--deny/--documents options (use --root / for the startup volume)"
            );
        }
        bail!(
            "no saved scope; pass --root or --allow to start an index (use --root / for the startup volume)"
        );
    }
    Ok(Scope {
        roots: requested.roots.clone(),
        allow: requested.allow.clone(),
        deny: requested.deny.clone(),
        documents: requested.documents,
        pdf_helper: requested.pdf_helper.clone(),
    })
}

/// Apply a newly narrowed scope before reading the filesystem. Clients which
/// already hold displayed hits can drop them when they submit the new scope.
pub(super) fn restrict_scope(conn: &mut Connection, coverage: &Coverage) -> Result<()> {
    let requested = serde_json::to_string(&coverage.scope)?;
    let tx = begin(conn)?;
    let prior: Option<String> = tx
        .query_row("SELECT value FROM info WHERE key='scope'", [], |r| r.get(0))
        .optional()?;
    if prior.as_deref() == Some(&requested) {
        return Ok(());
    }
    {
        let mut items = tx.prepare("SELECT id,path FROM item")?;
        let mut rows = items.query([])?;
        let mut exclude = tx.prepare("INSERT INTO stale VALUES(?)")?;
        while let Some(row) = rows.next()? {
            let path: String = row.get(1)?;
            if !coverage.contains(Path::new(&path)) {
                exclude.execute([row.get::<_, i64>(0)?])?;
            }
        }
    }
    purge(&tx)?;
    if !coverage.scope.documents {
        tx.execute_batch("DELETE FROM content_fts; DELETE FROM document; DELETE FROM document_state; DELETE FROM embedding;")?;
    }
    tx.execute("DELETE FROM info WHERE key='walk_sample'", [])?;
    write_info(&tx, "scope", &coverage.scope)?;
    tx.commit()?;
    Ok(())
}

#[derive(serde::Serialize, serde::Deserialize)]
struct WalkSample {
    entries: u64,
    saved_at: u64,
}

fn epoch_seconds() -> Option<u64> {
    Some(SystemTime::now().duration_since(UNIX_EPOCH).ok()?.as_secs())
}

fn previous_walk_entries(tx: &Transaction<'_>) -> Result<Option<u64>> {
    const SAMPLE_AGE_LIMIT: u64 = 7 * 24 * 60 * 60;
    let saved: Option<String> = tx
        .query_row(
            "SELECT value FROM info WHERE key='walk_sample'",
            [],
            |row| row.get(0),
        )
        .optional()?;
    let sample = saved.and_then(|raw| serde_json::from_str::<WalkSample>(&raw).ok());
    Ok(sample.and_then(|sample| {
        let age = epoch_seconds()?.checked_sub(sample.saved_at)?;
        (age <= SAMPLE_AGE_LIMIT && sample.entries > 0).then_some(sample.entries)
    }))
}

pub(super) fn reconcile(
    conn: &mut Connection,
    coverage: &Coverage,
    manual: bool,
    progress: Option<&ScanProgressReporter>,
) -> Result<ScanStats> {
    let started = Instant::now();
    #[cfg(target_os = "macos")]
    let _io = platform::NoMaterialization::enter()?;
    let tx = begin(conn)?;
    // An empty filename index has no old rows to look up or retire. Keep the
    // regular path for overlapping roots, document extraction and refreshes.
    let cold = !coverage.scope.documents
        && coverage.scope.roots.len() == 1
        && tx.query_row("SELECT NOT EXISTS(SELECT 1 FROM item)", [], |row| {
            row.get::<_, bool>(0)
        })?;
    if let Some(progress) = progress {
        let estimate = previous_walk_entries(&tx)?;
        progress.phase(ScanPhase::Scanning, 0, estimate);
    }
    let mut walk = Walk::new(&tx, coverage);
    walk.cold = cold;
    walk.progress = progress;
    for root in &coverage.scope.roots {
        walk.visit(root, true, true)?;
    }
    let entries = walk.entries;
    if let Some(progress) = progress {
        progress.phase(ScanPhase::Finalizing, entries, Some(entries));
    }
    let failed = manual && walk.readable_roots == 0;
    if failed {
        // Preserve the previous data on a failed manual scan and avoid
        // returning paths or contents we could not verify.
        tx.execute("INSERT OR IGNORE INTO unverified SELECT id FROM item", [])?;
    } else {
        if !cold {
            tx.execute(
                "INSERT INTO stale SELECT id FROM item WHERE id NOT IN (SELECT id FROM observed)
                 AND id NOT IN (SELECT id FROM unverified)",
                [],
            )?;
            purge(&tx)?;
        }
        if manual {
            crate::semantic::clear_model(&tx)?;
        }
    }
    hide_unverified(&tx)?;
    if cold {
        tx.execute(
            "INSERT INTO name_fts(rowid,name,full,initials,searchable_path)
             SELECT id,name,full,initials,searchable_path FROM item ORDER BY id",
            [],
        )?;
    }
    if !failed
        && walk.readable_roots == coverage.scope.roots.len()
        && walk.stats.entries_unreadable == 0
        && let Some(saved_at) = epoch_seconds()
    {
        write_info(&tx, "walk_sample", &WalkSample { entries, saved_at })?;
    } else {
        tx.execute("DELETE FROM info WHERE key='walk_sample'", [])?;
    }
    let mut stats = walk.stats;
    stats.roots = coverage
        .scope
        .roots
        .iter()
        .map(|p| p.display().to_string())
        .collect();
    stats.elapsed_ms = started.elapsed().as_millis();
    let prior_scan: bool = tx.query_row(
        "SELECT EXISTS(SELECT 1 FROM info WHERE key='scan')",
        [],
        |r| r.get(0),
    )?;
    if !failed || prior_scan {
        write_info(&tx, "scan", &stats)?;
    }
    tx.commit()?;
    if failed {
        bail!(
            "none of the requested roots could be enumerated; unverified records were retained and hidden"
        );
    }
    // Build the optional ordering index after committing current visibility,
    // so upgrading a large database cannot delay publishing exclusions.
    if let Err(error) = conn.execute_batch(crate::name_fast::CREATE_NAME_ORDER) {
        eprintln!("lumen: could not build name ordering index: {error}");
    }
    if let Some(progress) = progress {
        progress.phase(ScanPhase::Done, entries, Some(entries));
    }
    Ok(stats)
}

#[cfg(target_os = "macos")]
pub(super) fn apply_changes(
    conn: &mut Connection,
    coverage: &Coverage,
    targets: std::collections::BTreeMap<PathBuf, bool>,
) -> Result<(ScanStats, bool)> {
    let _io = platform::NoMaterialization::enter()?;
    let tx = begin(conn)?;
    let mut walk = Walk::new(&tx, coverage);
    for (path, recurse) in &targets {
        if path
            .ancestors()
            .skip(1)
            .any(|parent| targets.get(parent) == Some(&true))
        {
            continue;
        }
        let subtree = walk.visit(path, false, *recurse)?;
        if subtree {
            // An explicit nested root may be reachable only by starting at
            // that root, e.g. a temporary fixture under the system exclusions.
            for root in &coverage.scope.roots {
                if root != path
                    && root.starts_with(path)
                    && root
                        .ancestors()
                        .take_while(|p| *p != path)
                        .any(|p| !coverage.allows(p))
                {
                    walk.visit(root, true, true)?;
                }
            }
        }
        mark_stale(&tx, path, subtree)?;
    }
    let removed = purge(&tx)?;
    let hidden = hide_unverified(&tx)?;
    let (stats, changed) = (walk.stats, walk.changed || removed != 0 || hidden != 0);
    tx.commit()?;
    Ok((stats, changed))
}

fn begin(conn: &mut Connection) -> Result<Transaction<'_>> {
    conn.execute_batch(
        "CREATE TEMP TABLE IF NOT EXISTS observed(id INTEGER PRIMARY KEY);
         CREATE TEMP TABLE IF NOT EXISTS stale(id INTEGER PRIMARY KEY);
         CREATE TEMP TABLE IF NOT EXISTS unverified(id INTEGER PRIMARY KEY);",
    )?;
    let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
    tx.execute_batch("DELETE FROM observed; DELETE FROM stale; DELETE FROM unverified;")?;
    Ok(tx)
}

fn write_info(tx: &Transaction<'_>, key: &str, value: &impl serde::Serialize) -> Result<()> {
    tx.execute(
        "INSERT INTO info(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
        params![key, serde_json::to_string(value)?],
    )?;
    Ok(())
}

#[cfg(target_os = "macos")]
fn mark_stale(tx: &Transaction<'_>, path: &Path, subtree: bool) -> Result<()> {
    if let Some(path) = path.to_str() {
        if subtree {
            let base = path.strip_suffix('/').unwrap_or(path);
            // With the default binary collation, [base+'/', base+'0') contains
            // exactly the descendants, excluding similarly prefixed siblings.
            tx.prepare_cached(
                "INSERT OR IGNORE INTO stale SELECT id FROM item
                 WHERE (path=?1 OR (path>=?2 AND path<?3)) AND id NOT IN (SELECT id FROM observed)
                 AND id NOT IN (SELECT id FROM unverified)",
            )?
            .execute(params![path, format!("{base}/"), format!("{base}0")])?;
        } else {
            tx.prepare_cached(
                "INSERT OR IGNORE INTO stale SELECT id FROM item
                 WHERE path=? AND id NOT IN (SELECT id FROM observed)
                 AND id NOT IN (SELECT id FROM unverified)",
            )?
            .execute([path])?;
        }
    }
    Ok(())
}

fn hide_unverified(tx: &Transaction<'_>) -> Result<usize> {
    Ok(tx.execute(
        "UPDATE item SET availability='unverified' WHERE id IN (SELECT id FROM unverified)
         AND availability<>'unverified'",
        [],
    )?)
}

fn purge(tx: &Transaction<'_>) -> Result<usize> {
    tx.execute_batch(
        "DELETE FROM stale WHERE id IN (SELECT id FROM unverified) OR id IN (SELECT id FROM observed);
         DELETE FROM name_fts WHERE rowid IN (SELECT id FROM stale);
         DELETE FROM content_fts WHERE rowid IN (SELECT id FROM stale);
         DELETE FROM document WHERE id IN (SELECT id FROM stale);
         DELETE FROM document_state WHERE id IN (SELECT id FROM stale);
         DELETE FROM embedding WHERE id IN (SELECT id FROM stale);",
    )?;
    Ok(tx.execute("DELETE FROM item WHERE id IN (SELECT id FROM stale)", [])?)
}

struct Walk<'a> {
    tx: &'a Transaction<'a>,
    coverage: &'a Coverage,
    stats: ScanStats,
    cold: bool,
    entries: u64,
    progress: Option<&'a ScanProgressReporter>,
    readable_roots: usize,
    changed: bool,
    seen_directories: HashSet<(u64, u64)>,
    pinyin: HashMap<String, (String, String)>,
}

impl<'a> Walk<'a> {
    fn new(tx: &'a Transaction<'a>, coverage: &'a Coverage) -> Self {
        Self {
            tx,
            coverage,
            stats: ScanStats::default(),
            cold: false,
            entries: 0,
            progress: None,
            readable_roots: 0,
            changed: false,
            seen_directories: HashSet::new(),
            pinyin: HashMap::new(),
        }
    }

    /// Return whether the target's entire subtree was checked or must be purged.
    fn visit(&mut self, target: &Path, root: bool, recursive: bool) -> Result<bool> {
        if !self.coverage.allows(target) {
            return Ok(true);
        }
        // Targets may arrive directly, without the normal top-down walk of each
        // parent. Refuse symlink and dataless ancestors before probing a child.
        let mut parents: Vec<_> = target.ancestors().skip(1).collect();
        while let Some(parent) = parents.pop() {
            match fs::symlink_metadata(parent) {
                Ok(meta)
                    if meta.is_dir() && platform::availability(parent, &meta) != "placeholder" => {}
                Ok(_) => return Ok(true),
                Err(error) => {
                    if !confirmed_absent(&error) {
                        self.gap(target)?;
                    } else if root {
                        self.stats.entries_unreadable += 1;
                    }
                    return Ok(true);
                }
            }
        }
        let mut stack = vec![(target.to_path_buf(), root, None)];
        let mut subtree = recursive;
        while let Some((path, is_root, cached)) = stack.pop() {
            if let Some(progress) = self.progress
                && (self.entries <= 16 || self.entries.is_multiple_of(64))
            {
                progress.entries(self.entries);
            }
            self.entries += 1;
            if !self.coverage.allows(&path) {
                self.stats.skipped += 1;
                continue;
            }
            let metadata = match cached {
                Some(platform::FastInfo {
                    directory: false, ..
                }) => None,
                _ => match fs::symlink_metadata(&path) {
                    Ok(m) if m.is_file() || m.is_dir() => Some(m),
                    Ok(_) => {
                        self.stats.skipped += 1;
                        subtree |= path == target;
                        continue;
                    }
                    Err(error) => {
                        if !confirmed_absent(&error) {
                            self.gap(&path)?;
                        } else if is_root {
                            self.stats.entries_unreadable += 1;
                        }
                        subtree |= path == target;
                        continue;
                    }
                },
            };
            let (directory, availability) = match &metadata {
                Some(meta) => (meta.is_dir(), platform::availability(&path, meta)),
                None => (false, platform::classify(&path, cached.unwrap().dataless)),
            };
            if availability == "placeholder" {
                self.stats.placeholders += 1;
            } else if availability == "provider_metadata_only" {
                self.stats.provider_metadata_only += 1;
            }
            let Some(path_text) = path.to_str() else {
                self.stats.skipped += 1;
                continue;
            };
            let mut descend = recursive && directory && availability != "placeholder";
            if path != Path::new("/") {
                let display = path
                    .file_name()
                    .and_then(|name| name.to_str())
                    .unwrap_or(path_text);
                let kind = if directory { "directory" } else { "file" };
                if self.cold {
                    if self
                        .insert_item(path_text, display, kind, availability)?
                        .is_some()
                    {
                        self.stats.items += 1;
                    }
                } else {
                    let (id, prior, first) =
                        self.observe(path_text, display, kind, availability)?;
                    if directory
                        && availability != "placeholder"
                        && prior.as_deref() != Some(availability)
                    {
                        // New, replaced, or re-materialized directory, even if
                        // the notification described only the directory itself.
                        descend = true;
                    }
                    if first {
                        self.refresh_document(
                            id,
                            &path,
                            directory,
                            availability,
                            metadata.as_ref(),
                        )?;
                    }
                }
            }
            if path == target {
                subtree |= descend || !directory || availability == "placeholder";
            }
            if !descend {
                continue;
            }
            let meta = metadata.expect("directory metadata was read");
            if !self.seen_directories.insert((meta.dev(), meta.ino())) && !is_root {
                continue;
            }
            if let Some(children) = platform::bulk_children(&path) {
                self.stats.bulk_directories += 1;
                self.readable_roots += usize::from(is_root);
                stack.extend(
                    children
                        .into_iter()
                        .map(|(name, info)| (path.join(name), false, info)),
                );
            } else {
                self.stats.fallback_directories += 1;
                match platform::children(&path) {
                    Ok(children) => {
                        self.readable_roots += usize::from(is_root);
                        stack.extend(
                            children
                                .into_iter()
                                .map(|name| (path.join(name), false, None)),
                        );
                    }
                    Err(_) => self.gap(&path)?,
                }
            }
        }
        Ok(subtree)
    }

    fn gap(&mut self, path: &Path) -> Result<()> {
        self.stats.entries_unreadable += 1;
        if let Some(path) = path.to_str() {
            let base = path.strip_suffix('/').unwrap_or(path);
            self.tx.prepare_cached(
                "INSERT OR IGNORE INTO unverified SELECT id FROM item WHERE path=?1 OR (path>=?2 AND path<?3)",
            )?.execute(params![path, format!("{base}/"), format!("{base}0")])?;
        }
        Ok(())
    }

    fn observe(
        &mut self,
        path: &str,
        display: &str,
        kind: &str,
        availability: &str,
    ) -> Result<(i64, Option<String>, bool)> {
        let previous: Option<(i64, String, String)> = self
            .tx
            .prepare_cached("SELECT id,kind,availability FROM item WHERE path=?")?
            .query_row([path], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
            .optional()?;
        let (id, prior) = if let Some((id, old_kind, old_availability)) = previous {
            if old_kind != kind || old_availability != availability {
                self.changed = true;
                self.tx
                    .prepare_cached("UPDATE item SET kind=?,availability=? WHERE id=?")?
                    .execute(params![kind, availability, id])?;
            }
            (id, (old_kind == kind).then_some(old_availability))
        } else {
            let id = self
                .insert_item(path, display, kind, availability)?
                .context("new index row unexpectedly conflicts with an existing path")?;
            (id, None)
        };
        let first = self
            .tx
            .prepare_cached("INSERT OR IGNORE INTO observed VALUES(?)")?
            .execute([id])?
            != 0;
        self.stats.items += u64::from(first);
        Ok((id, prior, first))
    }

    fn insert_item(
        &mut self,
        path: &str,
        display: &str,
        kind: &str,
        availability: &str,
    ) -> Result<Option<i64>> {
        let (full, initials) = if display.is_ascii() {
            ("", "")
        } else {
            if self.pinyin.len() >= 4096 {
                self.pinyin.clear();
            }
            let (full, initials) = self
                .pinyin
                .entry(display.to_owned())
                .or_insert_with(|| platform::pinyin(display));
            (full.as_str(), initials.as_str())
        };
        let name = norm(display);
        let searchable_path = norm(path);
        let changed = self.tx.prepare_cached(
            "INSERT INTO item(path,display,kind,availability,name,full,initials,searchable_path)
             VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(path) DO NOTHING",
        )?.execute(params![path, display, kind, availability, name, full, initials, searchable_path])?;
        if changed == 0 {
            return Ok(None);
        }
        self.changed = true;
        let id = self.tx.last_insert_rowid();
        if !self.cold {
            self.tx.prepare_cached(
                "INSERT INTO name_fts(rowid,name,full,initials,searchable_path) VALUES(?,?,?,?,?)",
            )?.execute(params![id, name, full, initials, searchable_path])?;
        }
        Ok(Some(id))
    }

    fn refresh_document(
        &mut self,
        id: i64,
        path: &Path,
        directory: bool,
        availability: &str,
        metadata: Option<&fs::Metadata>,
    ) -> Result<()> {
        let Some(kind) = DocumentKind::for_path(path) else {
            return Ok(());
        };
        let available = kind != DocumentKind::Pdf || self.coverage.pdf_stamp.is_some();
        if !self.coverage.scope.documents || directory || !available {
            // A prior scope may have allowed extraction of this path.
            return self.clear_document(id);
        }
        self.read_document(id, path, availability, metadata, kind)
    }

    fn read_document(
        &mut self,
        id: i64,
        path: &Path,
        availability: &str,
        metadata: Option<&fs::Metadata>,
        kind: DocumentKind,
    ) -> Result<()> {
        let version = |meta: &fs::Metadata| {
            let extractor = match kind {
                DocumentKind::Text => "",
                DocumentKind::Docx => "docx-v1",
                DocumentKind::Pdf => self.coverage.pdf_stamp.as_deref().unwrap_or(""),
            };
            format!("{}:{extractor}", stamp(meta))
        };
        if availability == "local" {
            let fetched;
            let metadata = match metadata {
                Some(m) => Some(m),
                None => {
                    fetched = fs::symlink_metadata(path).ok();
                    fetched.as_ref()
                }
            };
            if let Some(meta) =
                metadata.filter(|m| m.is_file() && platform::availability(path, m) == "local")
            {
                let current = version(meta);
                let previous: Option<String> = self
                    .tx
                    .prepare_cached("SELECT stamp FROM document_state WHERE id=?")?
                    .query_row([id], |r| r.get(0))
                    .optional()?;
                if previous.as_deref() == Some(&current) {
                    self.stats.documents += 1;
                    return Ok(());
                }
                let body = match kind.extract(path, self.coverage.scope.pdf_helper.as_deref()) {
                    Err(error)
                        if error.downcast_ref::<std::io::Error>().is_some_and(|io| {
                            io.kind() == std::io::ErrorKind::PermissionDenied
                        }) =>
                    {
                        self.gap(path)?;
                        self.stats.documents_not_read += 1;
                        return Ok(());
                    }
                    other => other,
                };
                if let Ok(body) = body
                    && !body.is_empty()
                    && fs::symlink_metadata(path).is_ok_and(|m| {
                        m.is_file()
                            && platform::availability(path, &m) == "local"
                            && version(&m) == current
                    })
                {
                    let unchanged_legacy = previous.is_none()
                        && self
                            .tx
                            .prepare_cached(
                                "SELECT EXISTS(SELECT 1 FROM document WHERE id=? AND body=?)",
                            )?
                            .query_row(params![id, body], |r| r.get::<_, bool>(0))?;
                    if !unchanged_legacy {
                        self.clear_document(id)?;
                        let normalized = norm(&body);
                        self.tx
                            .prepare_cached("INSERT INTO document VALUES(?,?,?)")?
                            .execute(params![id, body, normalized])?;
                        self.tx
                            .prepare_cached("INSERT INTO content_fts(rowid,body) VALUES(?,?)")?
                            .execute(params![id, normalized])?;
                        self.changed = true;
                    }
                    self.tx
                        .prepare_cached("INSERT INTO document_state VALUES(?,?)")?
                        .execute(params![id, current])?;
                    self.stats.documents += 1;
                    return Ok(());
                }
            }
        }
        self.clear_document(id)?;
        self.stats.documents_not_read += 1;
        Ok(())
    }

    fn clear_document(&mut self, id: i64) -> Result<()> {
        if self
            .tx
            .prepare_cached("DELETE FROM document WHERE id=?")?
            .execute([id])?
            != 0
        {
            self.changed = true;
            self.tx
                .prepare_cached("DELETE FROM content_fts WHERE rowid=?")?
                .execute([id])?;
            self.tx
                .prepare_cached("DELETE FROM document_state WHERE id=?")?
                .execute([id])?;
            self.tx
                .prepare_cached("DELETE FROM embedding WHERE id=?")?
                .execute([id])?;
        }
        Ok(())
    }
}

fn confirmed_absent(error: &std::io::Error) -> bool {
    matches!(
        error.kind(),
        std::io::ErrorKind::NotFound | std::io::ErrorKind::NotADirectory
    )
}

fn stamp(meta: &fs::Metadata) -> String {
    format!(
        "{}:{}:{}:{}:{}:{}:{}",
        meta.dev(),
        meta.ino(),
        meta.len(),
        meta.mtime(),
        meta.mtime_nsec(),
        meta.ctime(),
        meta.ctime_nsec(),
    )
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum DocumentKind {
    Text,
    Docx,
    Pdf,
}

impl DocumentKind {
    fn for_path(path: &Path) -> Option<Self> {
        match path.extension()?.to_str()?.to_ascii_lowercase().as_str() {
            "txt" | "md" | "markdown" => Some(Self::Text),
            "docx" => Some(Self::Docx),
            "pdf" => Some(Self::Pdf),
            _ => None,
        }
    }

    fn extract(self, path: &Path, pdf_helper: Option<&Path>) -> Result<String> {
        match self {
            Self::Text => Ok(String::from_utf8(platform::read_local(
                path,
                MAX_DOCUMENT,
            )?)?),
            Self::Docx => docx::text(&platform::read_local(path, docx::MAX_ARCHIVE)?),
            Self::Pdf => extract_pdf(path, pdf_helper.context("missing PDF helper")?),
        }
    }
}

fn extract_pdf(path: &Path, helper: &Path) -> Result<String> {
    let bytes = platform::read_local(path, 24 * 1024 * 1024)?;
    let mut child = Command::new(helper)
        .process_group(0)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()?;
    // Input and output must be serviced concurrently to avoid pipe deadlock.
    let mut input = child.stdin.take().context("extractor input")?;
    let mut output = child
        .stdout
        .take()
        .context("extractor output")?
        .take(MAX_DOCUMENT + 1);
    let writer = std::thread::spawn(move || input.write_all(&bytes));
    let reader = std::thread::spawn(move || {
        let mut text = Vec::new();
        output.read_to_end(&mut text).map(|_| text)
    });
    let deadline = Instant::now() + Duration::from_secs(15);
    let status = loop {
        match child.try_wait() {
            Ok(Some(status)) if reader.is_finished() && writer.is_finished() => break status,
            Ok(_) if Instant::now() < deadline => std::thread::sleep(Duration::from_millis(5)),
            other => {
                // Kill the helper group so inherited pipe descriptors also close.
                unsafe { libc::kill(-(child.id() as libc::pid_t), libc::SIGKILL) };
                let _ = child.wait();
                other.context("wait for PDF extractor")?;
                bail!("PDF extraction timed out");
            }
        }
    };
    let text = reader
        .join()
        .map_err(|_| anyhow::anyhow!("extractor output failed"))??;
    writer
        .join()
        .map_err(|_| anyhow::anyhow!("extractor input failed"))??;
    if !status.success() || text.len() as u64 > MAX_DOCUMENT {
        bail!("PDF extraction failed or exceeded text limit");
    }
    Ok(String::from_utf8(text)?)
}
