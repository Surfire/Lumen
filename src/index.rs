use super::{
    MAX_DOCUMENT, PdfHelperPolicy, ScanPhase, ScanProgressReporter, ScanStats, Scope, absolute,
    docx, norm, open_write, platform, with_suffix,
};
use anyhow::{Context, Result, bail, ensure};
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

const APP_PDF_HELPER: &str = "LumenPdfExtractor";
// Bump this only when PDF extraction changes the indexed text format. Binary
// rebuilds, code signatures and app installs are compatible with this ID.
const APP_PDF_FORMAT: &str = "lumen-pdf:pdfkit-text-v2";

fn is_app_pdf_helper(path: &Path) -> bool {
    let Some(resources) = path.parent() else {
        return false;
    };
    let Some(contents) = resources.parent() else {
        return false;
    };
    path.file_name()
        .is_some_and(|name| name.eq_ignore_ascii_case(APP_PDF_HELPER))
        && resources
            .file_name()
            .is_some_and(|name| name.eq_ignore_ascii_case("Resources"))
        && contents
            .file_name()
            .is_some_and(|name| name.eq_ignore_ascii_case("Contents"))
        && contents
            .parent()
            .and_then(Path::extension)
            .is_some_and(|ext| ext.eq_ignore_ascii_case("app"))
}

#[derive(PartialEq, Eq)]
pub(super) struct PdfExtractor {
    executable: PathBuf,
    format: String,
    bundled_binary: Option<String>,
}

impl PdfExtractor {
    fn bundled() -> Result<Self> {
        let engine = fs::canonicalize(std::env::current_exe()?)?;
        let executable = engine.with_file_name(APP_PDF_HELPER);
        ensure!(
            is_app_pdf_helper(&executable),
            "--bundled-pdf-helper must be run from the app's Contents/Resources"
        );
        let bundled_binary = Self::bundled_binary_stamp(&executable)?;
        Ok(Self {
            executable,
            format: APP_PDF_FORMAT.into(),
            bundled_binary: Some(bundled_binary),
        })
    }

    fn manual(path: &Path) -> Self {
        let metadata = fs::metadata(path).ok();
        Self {
            executable: path.to_owned(),
            format: format!("{path:?}:{:?}", metadata.as_ref().map(stamp)),
            bundled_binary: None,
        }
    }

    fn bundled_binary_stamp(path: &Path) -> Result<String> {
        let metadata =
            fs::symlink_metadata(path).context("read the current app's bundled PDF extractor")?;
        ensure!(
            metadata.is_file() && metadata.mode() & 0o111 != 0,
            "the current app's PDF extractor must be an executable regular file"
        );
        Ok(stamp(&metadata))
    }

    fn executable(&self) -> Result<&Path> {
        if let Some(binary) = &self.bundled_binary {
            ensure!(
                *binary == Self::bundled_binary_stamp(&self.executable)?,
                "bundled PDF extractor changed while running; restart from the current app"
            );
        }
        Ok(&self.executable)
    }

    fn can_restamp_legacy(&self, previous: &str, document_stamp: &str) -> bool {
        self.bundled_binary.is_some()
            && previous
                .strip_prefix(document_stamp)
                .is_some_and(|suffix| suffix.starts_with(":\""))
    }
}

pub(super) const INDEX_SIDECARS: [&str; 5] =
    ["-wal", "-shm", "-journal", "-watch-lock", "-external"];

fn opaque_package(path: &Path) -> bool {
    const EXTENSIONS: &[&str] = &[
        "app",
        "framework",
        "bundle",
        "xcodeproj",
        "xcworkspace",
        "photoslibrary",
        "musiclibrary",
        "fcpbundle",
        "imovielibrary",
        "playground",
        "xcarchive",
        "dsym",
        "lproj",
        "kext",
        "plugin",
        "appex",
        "xpc",
    ];
    path.extension().is_some_and(|extension| {
        EXTENSIONS
            .iter()
            .any(|candidate| extension.eq_ignore_ascii_case(candidate))
    })
}

pub(super) fn is_index_path(path: &Path, database: &Path, sidecars: &[PathBuf]) -> bool {
    path == database || sidecars.iter().any(|sidecar| path.starts_with(sidecar))
}

pub(super) struct Coverage {
    pub scope: Scope,
    database: PathBuf,
    sidecars: [PathBuf; INDEX_SIDECARS.len()],
    pub(super) pdf: Option<PdfExtractor>,
    external: Option<crate::external::Boundary>,
}

impl Coverage {
    pub fn new(database: PathBuf, scope: &Scope) -> Result<Self> {
        let paths = |p: &[PathBuf]| -> Result<Vec<PathBuf>> {
            p.iter()
                .map(|p| absolute(p).map(|p| platform::filesystem_spelling(&p)))
                .collect()
        };
        let roots = paths(&scope.roots())?;
        let allow = paths(&scope.allow)?;
        let contains_volume = roots.iter().any(|p| p == Path::new("/"))
            && (allow.is_empty() || allow.iter().any(|p| p == Path::new("/")));
        let mut content_roots = scope.content_roots.as_deref().map(paths).transpose()?;
        if let Some(roots) = &mut content_roots {
            ensure!(
                !roots.iter().any(|root| root == Path::new("/")),
                "choose a document folder below the volume root"
            );
            roots.sort();
            roots.dedup();
        } else {
            ensure!(
                !scope.documents || !contains_volume,
                "document indexing requires an explicit folder; pass --content-root"
            );
        }
        let managed = scope.pdf_helper_policy == Some(PdfHelperPolicy::Bundled);
        ensure!(
            !managed || scope.documents,
            "--bundled-pdf-helper requires document indexing in the requested or saved scope"
        );
        ensure!(
            !managed || scope.pdf_helper.is_none(),
            "bundled and manual PDF helpers are mutually exclusive"
        );
        let scope = Scope {
            roots,
            allow,
            deny: paths(&scope.deny)?,
            documents: scope.documents,
            content_roots,
            pdf_helper: scope.pdf_helper.as_deref().map(absolute).transpose()?,
            pdf_helper_policy: scope
                .pdf_helper_policy
                .or_else(|| scope.pdf_helper.as_ref().map(|_| PdfHelperPolicy::Manual)),
        };
        let database = platform::filesystem_spelling(&database);
        let sidecars = INDEX_SIDECARS.map(|suffix| with_suffix(&database, suffix));
        let pdf = if managed {
            Some(PdfExtractor::bundled()?)
        } else {
            scope.pdf_helper.as_deref().map(PdfExtractor::manual)
        };
        Ok(Self {
            scope,
            database,
            sidecars,
            pdf,
            external: None,
        })
    }

    #[cfg(target_os = "macos")]
    pub fn refreshed(&self) -> Result<Self> {
        let refreshed = Self::new(self.database.clone(), &self.scope)?;
        if self.scope.pdf_helper_policy == Some(PdfHelperPolicy::Bundled) {
            ensure!(
                self.pdf == refreshed.pdf,
                "bundled PDF extractor changed during watch; restart from the current app"
            );
        }
        Ok(refreshed)
    }

    pub(super) fn contains(&self, path: &Path) -> bool {
        self.scope.roots.iter().any(|root| path.starts_with(root)) && self.allows(path)
    }

    pub(super) fn permits_content(&self, path: &Path) -> bool {
        self.scope.documents
            && self.contains(path)
            && self.scope.content_roots.as_ref().is_none_or(|roots| {
                roots
                    .iter()
                    .any(|root| path != root && path.starts_with(root))
            })
    }

    pub fn allows(&self, path: &Path) -> bool {
        self.external.as_ref().map_or_else(
            || !crate::external::is_external(path),
            |boundary| boundary.allows(path),
        ) && self.scope.allows(path)
            && !is_index_path(path, &self.database, &self.sidecars)
            && self
                .scope
                .roots
                .iter()
                .filter(|root| path.starts_with(root))
                .max_by_key(|root| root.components().count())
                .is_none_or(|root| {
                    !path
                        .ancestors()
                        .skip(1)
                        .take_while(|parent| parent.starts_with(root))
                        .any(opaque_package)
                })
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
    crate::external::check_primary_scope(scope)?;
    let file = absolute(database)?;
    let coverage = Coverage::new(file.clone(), scope)?;
    crate::external::check_primary_scope(&coverage.scope)?;
    let (mut conn, _lease) =
        open_write(&file, true).with_context(|| format!("open index {}", file.display()))?;
    restrict_scope(&mut conn, &coverage)?;
    #[cfg(target_os = "macos")]
    let checkpoint = crate::watch::checkpoint_before_scan(&conn, &coverage)?;
    let stats = reconcile(&mut conn, &coverage, true, progress)?;
    #[cfg(target_os = "macos")]
    checkpoint(&conn)?;
    Ok(stats)
}

pub(super) fn scan_external(
    catalog: &Path,
    conn: &mut Connection,
    boundary: crate::external::Boundary,
    mut deny: Vec<PathBuf>,
    progress: Option<&ScanProgressReporter>,
) -> Result<ScanStats> {
    #[cfg(target_os = "macos")]
    let _io = platform::NoMaterialization::enter()?;
    ensure!(
        boundary.device().is_some(),
        "external volume device is unverified"
    );
    let root = boundary.root().to_owned();
    deny.extend(
        [
            "System",
            "Applications",
            "Library",
            "private",
            "dev",
            "bin",
            "sbin",
            "usr",
            "etc",
            "var",
            "Network",
            "Volumes",
            "cores",
            "Users/Shared",
            "Backups.backupdb",
        ]
        .into_iter()
        .map(|name| root.join(name)),
    );
    let scope = Scope {
        roots: vec![root.clone()],
        deny,
        ..Scope::default()
    };
    let mut coverage = Coverage::new(catalog.to_owned(), &scope)?;
    coverage.external = Some(boundary);
    restrict_scope(conn, &coverage)?;
    reconcile(conn, &coverage, true, progress)
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
            let mut saved: Scope =
                serde_json::from_str(&stored).context("read saved watch scope")?;
            if saved.content_roots.is_none()
                && saved.documents
                && (saved.allow.is_empty() || saved.allow.iter().any(|p| p == Path::new("/")))
                && saved.roots.iter().any(|p| p == Path::new("/"))
            {
                saved.documents = false;
                saved.content_roots = Some(Vec::new());
                saved.pdf_helper = None;
                saved.pdf_helper_policy = None;
            }
            if requested.pdf_helper_policy == Some(PdfHelperPolicy::Bundled)
                && saved.documents
                && saved.pdf_helper_policy != Some(PdfHelperPolicy::Manual)
            {
                saved.pdf_helper = None;
                saved.pdf_helper_policy = Some(PdfHelperPolicy::Bundled);
            } else if saved.pdf_helper_policy == Some(PdfHelperPolicy::Bundled)
                || (saved.pdf_helper_policy.is_none()
                    && saved.pdf_helper.as_deref().is_some_and(is_app_pdf_helper))
            {
                bail!(
                    "saved scope uses an app PDF extractor; use --bundled-pdf-helper from the current app or supply an explicit --pdf-helper with its scope"
                );
            }
            return Ok(saved);
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
    Ok(requested.clone())
}

/// Apply a newly narrowed scope before reading the filesystem. Clients which
/// already hold displayed hits can drop them when they submit the new scope.
pub(super) fn restrict_scope(conn: &mut Connection, coverage: &Coverage) -> Result<()> {
    let requested = serde_json::to_string(&coverage.scope)?;
    let tx = begin(conn)?;
    let prior: Option<String> = tx
        .query_row("SELECT value FROM info WHERE key='scope'", [], |r| r.get(0))
        .optional()?;
    let policy_reconciled = tx.query_row(
        "SELECT EXISTS(SELECT 1 FROM info WHERE key='scope_policy_v3')",
        [],
        |r| r.get::<_, bool>(0),
    )?;
    if policy_reconciled && prior.as_deref() == Some(&requested) {
        return Ok(());
    }
    let same_names = policy_reconciled
        && prior
            .as_deref()
            .and_then(|raw| serde_json::from_str::<Scope>(raw).ok())
            .is_some_and(|scope| {
                scope.roots == coverage.scope.roots
                    && scope.allow == coverage.scope.allow
                    && scope.deny == coverage.scope.deny
            });
    if !same_names {
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
        tx.execute_batch("DELETE FROM content_fts; DELETE FROM document; DELETE FROM document_state; DELETE FROM embedding; DELETE FROM content_job;")?;
    } else if coverage.scope.content_roots.is_some() {
        crate::content::restrict_and_seed(&tx, coverage)?;
    }
    if !same_names {
        tx.execute("DELETE FROM info WHERE key='walk_sample'", [])?;
    }
    write_info(&tx, "scope", &coverage.scope)?;
    write_info(&tx, "scope_policy_v3", &true)?;
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

#[cfg(target_os = "macos")]
pub(super) fn reconciliation_overdue(conn: &Connection, limit: Duration) -> Result<bool> {
    let completed: Option<String> = conn
        .query_row(
            "SELECT value FROM info WHERE key='watch_reconciled_at'",
            [],
            |r| r.get(0),
        )
        .optional()?;
    let completed = match completed {
        Some(completed) => completed.parse::<u64>().ok(),
        None => {
            let sample: Option<String> = conn
                .query_row("SELECT value FROM info WHERE key='walk_sample'", [], |r| {
                    r.get(0)
                })
                .optional()?;
            sample
                .as_deref()
                .and_then(|sample| serde_json::from_str::<WalkSample>(sample).ok())
                .map(|sample| sample.saved_at)
        }
    };
    Ok(epoch_seconds()
        .zip(completed)
        .and_then(|(now, completed)| now.checked_sub(completed))
        .is_none_or(|age| age >= limit.as_secs()))
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
    tx.commit()?;
    let mut walk = Walk::new(conn, coverage);
    walk.cold = cold;
    walk.progress = progress;
    for root in &coverage.scope.roots {
        walk.visit(root, true, true)?;
    }
    walk.flush()?;
    let entries = walk.entries;
    let tx = Transaction::new_unchecked(conn, TransactionBehavior::Immediate)?;
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
    }
    hide_unverified(&tx)?;
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
    stats.entries_visited = entries;
    let prior_scan: bool = tx.query_row(
        "SELECT EXISTS(SELECT 1 FROM info WHERE key='scan')",
        [],
        |r| r.get(0),
    )?;
    if !failed || prior_scan {
        write_info(&tx, "scan", &stats)?;
    }
    #[cfg(target_os = "macos")]
    if !failed && let Some(now) = epoch_seconds() {
        write_info(&tx, "watch_reconciled_at", &now)?;
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
    crate::name_fast::install_han_ending(conn);
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
    begin(conn)?.commit()?;
    let mut walk = Walk::new(conn, coverage);
    let mut checked = Vec::new();
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
            // that root. Include the event target: it may itself be opaque.
            for root in &coverage.scope.roots {
                if root != path
                    && root.starts_with(path)
                    && root
                        .ancestors()
                        .skip(1)
                        .take_while(|p| p.starts_with(path))
                        .any(|p| opaque_package(p) || !coverage.allows(p))
                {
                    walk.visit(root, true, true)?;
                }
            }
        }
        checked.push((path, subtree));
    }
    walk.flush()?;
    let tx = Transaction::new_unchecked(conn, TransactionBehavior::Immediate)?;
    for (path, subtree) in checked {
        mark_stale(&tx, path, subtree)?;
    }
    let removed = purge(&tx)?;
    let hidden = hide_unverified(&tx)?;
    walk.stats.entries_visited = walk.entries;
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

const WRITE_BATCH: usize = 5000;

enum Pending {
    Item {
        path: PathBuf,
        directory: bool,
        availability: &'static str,
        legacy: Option<Box<LegacyDocument>>,
        content: Option<crate::content::Observation>,
    },
    Gap(PathBuf),
}

enum LegacyDocument {
    Current,
    Unreadable,
    Empty,
    Extracted {
        stamp: String,
        restamp: bool,
        text: crate::content::Extracted,
    },
}

struct Walk<'a> {
    conn: &'a Connection,
    tx: Option<Transaction<'a>>,
    pending: Vec<Pending>,
    scratch: Vec<u64>,
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
    fn new(conn: &'a Connection, coverage: &'a Coverage) -> Self {
        Self {
            conn,
            tx: None,
            pending: Vec::with_capacity(WRITE_BATCH),
            scratch: Vec::new(),
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
            if let Some(boundary) = &self.coverage.external
                && metadata
                    .as_ref()
                    .is_none_or(|metadata| Some(metadata.dev()) != boundary.device())
            {
                self.stats.skipped += 1;
                continue;
            }
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
            let opaque = directory && opaque_package(&path);
            let mut descend = recursive && directory && availability != "placeholder" && !opaque;
            if !recursive && directory && availability != "placeholder" && !opaque {
                let prior: Option<(String, String)> = self
                    .conn
                    .prepare_cached("SELECT kind,availability FROM item WHERE path=?")?
                    .query_row([path_text], |row| Ok((row.get(0)?, row.get(1)?)))
                    .optional()?;
                // New, replaced, or re-materialized directory, even if
                // the notification described only the directory itself.
                descend = prior
                    .as_ref()
                    .is_none_or(|(kind, old)| kind != "directory" || old != availability);
            }
            if path != Path::new("/") && !super::scope_ancestor(&path) {
                let mut legacy = None;
                let mut content = None;
                if !directory
                    && self.coverage.permits_content(&path)
                    && let Some(kind) = DocumentKind::for_path(&path)
                    && (kind != DocumentKind::Pdf || self.coverage.pdf.is_some())
                {
                    // Bulk enumeration omits document version metadata. Fetch
                    // it here, before the pending batch can acquire a write lock.
                    let fetched;
                    let meta = match (availability, metadata.as_ref()) {
                        ("local", Some(meta)) => Some(meta),
                        ("local", None) => match fs::symlink_metadata(&path) {
                            Ok(meta) => {
                                fetched = meta;
                                Some(&fetched)
                            }
                            Err(error) if confirmed_absent(&error) => None,
                            Err(_) => {
                                self.gap(&path)?;
                                continue;
                            }
                        },
                        _ => None,
                    }
                    .filter(|meta| {
                        meta.is_file() && platform::availability(&path, meta) == "local"
                    });
                    if self.coverage.scope.content_roots.is_none() {
                        let document = self.read_document(&path, meta, kind)?;
                        if matches!(document, LegacyDocument::Unreadable) {
                            self.stats.documents_not_read += 1;
                            self.gap(&path)?;
                            continue;
                        }
                        legacy = Some(Box::new(document));
                    } else if availability == "local" {
                        match crate::content::prepare(self.conn, self.coverage, &path, meta, kind)?
                        {
                            Some(observation) => content = Some(observation),
                            None => {
                                self.gap(&path)?;
                                continue;
                            }
                        }
                    }
                }
                // Do not accumulate extracted document bodies in a metadata batch.
                let flush_document = legacy.is_some();
                self.pending.push(Pending::Item {
                    path: path.clone(),
                    directory,
                    availability,
                    legacy,
                    content,
                });
                if flush_document || self.pending.len() >= WRITE_BATCH {
                    self.flush()?;
                }
            }
            if path == target {
                subtree |= descend || opaque || !directory || availability == "placeholder";
                self.readable_roots +=
                    usize::from(is_root && opaque && availability != "placeholder");
            }
            if !descend {
                continue;
            }
            let meta = metadata.expect("directory metadata was read");
            if !self.seen_directories.insert((meta.dev(), meta.ino())) && !is_root {
                continue;
            }
            if self.coverage.external.is_none()
                && let Some(children) = platform::bulk_children(&path, &mut self.scratch)
            {
                self.stats.bulk_directories += 1;
                self.readable_roots += usize::from(is_root);
                stack.extend(
                    children
                        .into_iter()
                        .map(|(name, info)| (path.join(name), false, info)),
                );
            } else {
                self.stats.fallback_directories += 1;
                match platform::children_on_device(
                    &path,
                    self.coverage
                        .external
                        .as_ref()
                        .and_then(|boundary| boundary.device()),
                ) {
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

    fn tx(&self) -> &Transaction<'a> {
        self.tx.as_ref().expect("writer batch is active")
    }

    fn flush(&mut self) -> Result<()> {
        if self.pending.is_empty() {
            return Ok(());
        }
        self.tx = Some(Transaction::new_unchecked(
            self.conn,
            TransactionBehavior::Immediate,
        )?);
        let first_id: i64 = if self.cold {
            self.tx()
                .query_row("SELECT coalesce(max(id),0) FROM item", [], |row| row.get(0))?
        } else {
            0
        };
        let pending = std::mem::take(&mut self.pending);
        for entry in &pending {
            match entry {
                Pending::Gap(path) => {
                    if let Some(path) = path.to_str() {
                        let base = path.strip_suffix('/').unwrap_or(path);
                        self.tx().prepare_cached(
                            "INSERT OR IGNORE INTO unverified SELECT id FROM item WHERE path=?1 OR (path>=?2 AND path<?3)",
                        )?.execute(params![path, format!("{base}/"), format!("{base}0")])?;
                    }
                }
                Pending::Item {
                    path,
                    directory,
                    availability,
                    legacy,
                    content,
                } => {
                    let path_text = path.to_str().expect("checked UTF-8 path");
                    let display = path
                        .file_name()
                        .and_then(|name| name.to_str())
                        .unwrap_or(path_text);
                    let kind = if *directory { "directory" } else { "file" };
                    if self.cold {
                        if self
                            .insert_item(path_text, display, kind, availability)?
                            .is_some()
                        {
                            self.stats.items += 1;
                        }
                    } else {
                        let (id, _, first) =
                            self.observe(path_text, display, kind, availability)?;
                        if first {
                            if let Some(document) = legacy {
                                self.apply_document(id, document)?;
                            } else if let Some(observation) = content {
                                self.changed |=
                                    crate::content::observe(self.tx(), id, observation)?;
                            } else if DocumentKind::for_path(path).is_some() {
                                self.changed |= crate::content::retire(self.tx(), id)?;
                            }
                        }
                    }
                }
            }
        }
        if self.cold {
            self.tx().execute(
                "INSERT INTO name_fts(rowid,name,full,initials,searchable_path)
                 SELECT id,name,full,initials,searchable_path FROM item WHERE id>? ORDER BY id",
                [first_id],
            )?;
        }
        // Lookups may run between flushes. Publish access gaps atomically
        // with observations instead of waiting for finalization to hide them.
        self.changed |= hide_unverified(self.tx())? != 0;
        self.tx.take().expect("writer batch is active").commit()?;
        self.pending = pending;
        self.pending.clear();
        Ok(())
    }

    fn gap(&mut self, path: &Path) -> Result<()> {
        self.stats.entries_unreadable += 1;
        self.pending.push(Pending::Gap(path.to_owned()));
        if self.pending.len() >= WRITE_BATCH {
            self.flush()?;
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
            .tx()
            .prepare_cached("SELECT id,kind,availability FROM item WHERE path=?")?
            .query_row([path], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
            .optional()?;
        let (id, prior) = if let Some((id, old_kind, old_availability)) = previous {
            if old_kind != kind || old_availability != availability {
                self.changed = true;
                self.tx()
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
            .tx()
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
        let tx = self.tx.as_ref().expect("writer batch is active");
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
        let changed = tx.prepare_cached(
            "INSERT INTO item(path,display,kind,availability,name,full,initials,searchable_path)
             VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(path) DO NOTHING",
        )?.execute(params![path, display, kind, availability, name, full, initials, searchable_path])?;
        if changed == 0 {
            return Ok(None);
        }
        self.changed = true;
        let id = tx.last_insert_rowid();
        if !self.cold {
            tx.prepare_cached(
                "INSERT INTO name_fts(rowid,name,full,initials,searchable_path) VALUES(?,?,?,?,?)",
            )?
            .execute(params![id, name, full, initials, searchable_path])?;
        }
        Ok(Some(id))
    }

    fn read_document(
        &self,
        path: &Path,
        metadata: Option<&fs::Metadata>,
        kind: DocumentKind,
    ) -> Result<LegacyDocument> {
        let version = |meta: &fs::Metadata| document_version(self.coverage, kind, meta);
        if let Some(meta) = metadata {
            let current = version(meta);
            let previous: Option<String> = self
                    .conn
                    .prepare_cached(
                        "SELECT ds.stamp FROM item i JOIN document_state ds ON i.id=ds.id WHERE i.path=?",
                    )?
                    .query_row([path.to_str().expect("checked UTF-8 path")], |r| r.get(0))
                    .optional()?;
            if previous.as_deref() == Some(&current) {
                return Ok(if can_open_document(path, meta) {
                    LegacyDocument::Current
                } else {
                    LegacyDocument::Unreadable
                });
            }
            let extracted = extract_document(self.coverage, path, kind);
            if kind == DocumentKind::Pdf
                && let Some(pdf) = &self.coverage.pdf
            {
                pdf.executable()?;
            }
            let body = match extracted {
                Err(error)
                    if error
                        .downcast_ref::<std::io::Error>()
                        .is_some_and(|io| io.kind() == std::io::ErrorKind::PermissionDenied) =>
                {
                    return Ok(LegacyDocument::Unreadable);
                }
                other => other,
            };
            if let Ok(body) = body
                && !body.body.is_empty()
                && fs::symlink_metadata(path).is_ok_and(|m| {
                    m.is_file()
                        && platform::availability(path, &m) == "local"
                        && version(&m) == current
                })
            {
                // The old stamp identified a binary path, not an extraction
                // format. Verify its text once with the current app. Existing
                // vectors are valid only if the exact same text was produced.
                let legacy = previous.is_none()
                    || (kind == DocumentKind::Pdf
                        && previous.as_deref().is_some_and(|prior| {
                            self.coverage
                                .pdf
                                .as_ref()
                                .is_some_and(|pdf| pdf.can_restamp_legacy(prior, &stamp(meta)))
                        }));
                return Ok(LegacyDocument::Extracted {
                    stamp: current,
                    restamp: legacy,
                    text: body,
                });
            }
        }
        Ok(LegacyDocument::Empty)
    }

    fn apply_document(&mut self, id: i64, document: &LegacyDocument) -> Result<()> {
        match document {
            LegacyDocument::Current => self.stats.documents += 1,
            LegacyDocument::Unreadable => unreachable!("staged as an access gap"),
            LegacyDocument::Empty => {
                self.clear_document(id)?;
                self.stats.documents_not_read += 1;
            }
            LegacyDocument::Extracted {
                stamp,
                restamp,
                text,
            } => {
                let unchanged_legacy = *restamp
                    && self
                        .tx()
                        .prepare_cached(
                            "SELECT EXISTS(SELECT 1 FROM document WHERE id=? AND body=?)",
                        )?
                        .query_row(params![id, text.body], |r| r.get::<_, bool>(0))?;
                if unchanged_legacy {
                    store_document_state(self.tx(), id, stamp, &text.pages)?;
                } else {
                    self.changed |= save_document(self.tx(), id, stamp, text)?;
                }
                self.stats.documents += 1;
            }
        }
        Ok(())
    }

    fn clear_document(&mut self, id: i64) -> Result<()> {
        self.changed |= remove_document(self.tx(), id)?;
        Ok(())
    }
}

/// Verify access to the same local document version without reading bytes.
pub(super) fn can_open_document(path: &Path, expected: &fs::Metadata) -> bool {
    use std::os::unix::fs::OpenOptionsExt;
    #[cfg(target_os = "macos")]
    let flags = libc::O_NOFOLLOW_ANY | libc::O_NONBLOCK;
    #[cfg(not(target_os = "macos"))]
    let flags = libc::O_NOFOLLOW | libc::O_NONBLOCK;
    fs::OpenOptions::new()
        .read(true)
        .custom_flags(flags)
        .open(path)
        .and_then(|file| file.metadata())
        .is_ok_and(|opened| {
            opened.is_file()
                && platform::availability(path, &opened) == "local"
                && stamp(&opened) == stamp(expected)
        })
}

pub(super) fn document_version(
    coverage: &Coverage,
    kind: DocumentKind,
    meta: &fs::Metadata,
) -> String {
    let extractor = match kind {
        DocumentKind::Text => "",
        DocumentKind::Docx => "docx-v1",
        DocumentKind::Pdf => coverage.pdf.as_ref().map_or("", |pdf| pdf.format.as_str()),
    };
    format!("{}:{extractor}", stamp(meta))
}

pub(super) fn extract_document(
    coverage: &Coverage,
    path: &Path,
    kind: DocumentKind,
) -> Result<crate::content::Extracted> {
    let pdf = (kind == DocumentKind::Pdf)
        .then_some(coverage.pdf.as_ref())
        .flatten();
    let result = kind.extract(path, pdf);
    if let Some(pdf) = pdf {
        pdf.executable()?;
    }
    result
}

pub(super) fn remove_document(conn: &Connection, id: i64) -> Result<bool> {
    let changed = conn
        .prepare_cached("DELETE FROM document WHERE id=?")?
        .execute([id])?
        != 0;
    if changed {
        conn.prepare_cached("DELETE FROM content_fts WHERE rowid=?")?
            .execute([id])?;
        conn.prepare_cached("DELETE FROM document_state WHERE id=?")?
            .execute([id])?;
        conn.prepare_cached("DELETE FROM embedding WHERE id=?")?
            .execute([id])?;
    }
    Ok(changed)
}

pub(super) fn save_document(
    conn: &Connection,
    id: i64,
    version: &str,
    extracted: &crate::content::Extracted,
) -> Result<bool> {
    remove_document(conn, id)?;
    let normalized = norm(&extracted.body);
    conn.prepare_cached("INSERT INTO document VALUES(?,?,?)")?
        .execute(params![id, extracted.body, normalized])?;
    conn.prepare_cached("INSERT INTO content_fts(rowid,body) VALUES(?,?)")?
        .execute(params![id, normalized])?;
    store_document_state(conn, id, version, &extracted.pages)?;
    Ok(true)
}

fn store_document_state(
    conn: &Connection,
    id: i64,
    version: &str,
    pages: &[crate::content::PageSpan],
) -> Result<()> {
    conn.prepare_cached(
        "INSERT INTO document_state VALUES(?,?) ON CONFLICT(id) DO UPDATE SET stamp=excluded.stamp",
    )?
    .execute(params![id, version])?;
    for page in pages {
        conn.prepare_cached("INSERT OR REPLACE INTO pdf_page VALUES(?,?,?,?)")?
            .execute(params![id, page.number, page.start as i64, page.end as i64])?;
    }
    Ok(())
}

fn confirmed_absent(error: &std::io::Error) -> bool {
    matches!(
        error.kind(),
        std::io::ErrorKind::NotFound | std::io::ErrorKind::NotADirectory
    )
}

pub(super) fn stamp(meta: &fs::Metadata) -> String {
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
pub(super) enum DocumentKind {
    Text,
    Docx,
    Pdf,
}

impl DocumentKind {
    pub(super) fn for_path(path: &Path) -> Option<Self> {
        match path.extension()?.to_str()?.to_ascii_lowercase().as_str() {
            "txt" | "md" | "markdown" => Some(Self::Text),
            "docx" => Some(Self::Docx),
            "pdf" => Some(Self::Pdf),
            _ => None,
        }
    }

    fn extract(self, path: &Path, pdf: Option<&PdfExtractor>) -> Result<crate::content::Extracted> {
        let body = match self {
            Self::Text => String::from_utf8(platform::read_local(path, MAX_DOCUMENT)?)?,
            Self::Docx => docx::text(&platform::read_local(path, docx::MAX_ARCHIVE)?)?,
            Self::Pdf => return extract_pdf(path, pdf.context("missing PDF helper")?),
        };
        Ok(crate::content::Extracted {
            body,
            pages: Vec::new(),
        })
    }
}

fn extract_pdf(path: &Path, helper: &PdfExtractor) -> Result<crate::content::Extracted> {
    let bytes = platform::read_local(path, 24 * 1024 * 1024)?;
    let mut command = Command::new(helper.executable()?);
    let pages = helper.bundled_binary.is_some();
    if pages {
        command.arg("--pages-v1");
    }
    let mut child = command
        .process_group(0)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()?;
    // Input and output must be serviced concurrently to avoid pipe deadlock.
    let mut input = child.stdin.take().context("extractor input")?;
    let limit = if pages {
        3 * MAX_DOCUMENT
    } else {
        MAX_DOCUMENT
    };
    let mut output = child
        .stdout
        .take()
        .context("extractor output")?
        .take(limit + 1);
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
    if !status.success() || text.len() as u64 > limit {
        bail!("PDF extraction failed or exceeded text limit");
    }
    if pages {
        crate::content::parse_pages(&text)
    } else {
        Ok(crate::content::Extracted {
            body: String::from_utf8(text)?,
            pages: Vec::new(),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Fixture(PathBuf);

    impl Fixture {
        fn new(name: &str) -> Self {
            let root = fs::canonicalize(std::env::temp_dir())
                .unwrap()
                .join(format!("lumen-index-{name}-{}", std::process::id()));
            let _ = fs::remove_dir_all(&root);
            fs::create_dir_all(&root).unwrap();
            Self(root)
        }
    }

    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    fn paths(conn: &Connection) -> Vec<String> {
        conn.prepare("SELECT path FROM item ORDER BY path")
            .unwrap()
            .query_map([], |row| row.get(0))
            .unwrap()
            .collect::<rusqlite::Result<_>>()
            .unwrap()
    }

    #[test]
    fn lumen_directory_is_not_an_index_artifact() {
        let fixture = Fixture::new("lumen-directory");
        let root = fixture.0.join("Lumen");
        fs::create_dir(&root).unwrap();
        let database = root.join("index.db");
        let document = root.join("notes.txt");
        fs::write(&document, "keep this searchable").unwrap();
        fs::create_dir(root.join("other")).unwrap();
        scan(
            &database,
            &Scope {
                roots: vec![root.clone()],
                ..Scope::default()
            },
        )
        .unwrap();
        let conn = super::super::open_read(&database).unwrap();
        let indexed = paths(&conn);
        assert!(indexed.contains(&document.to_str().unwrap().to_owned()));
        assert!(indexed.contains(&root.join("other").to_str().unwrap().to_owned()));
        assert!(!indexed.contains(&database.to_str().unwrap().to_owned()));
        assert!(!indexed.iter().any(|path| {
            INDEX_SIDECARS
                .iter()
                .any(|suffix| path == &format!("{}{suffix}", database.display()))
        }));
    }

    #[test]
    fn packages_are_opaque_but_explicit_nested_roots_work() {
        let fixture = Fixture::new("packages");
        let root = fixture.0.join("files");
        fs::create_dir(&root).unwrap();
        let extensions = [
            "APP",
            "framework",
            "bundle",
            "xcodeproj",
            "xcworkspace",
            "photoslibrary",
            "musiclibrary",
            "fcpbundle",
            "imovielibrary",
            "playground",
            "xcarchive",
            "dSYM",
            "lproj",
            "kext",
            "plugin",
            "appex",
            "xpc",
        ];
        let database = fixture.0.join("index.db");
        for extension in extensions {
            let package = root.join(format!("Example.{extension}"));
            fs::create_dir(&package).unwrap();
            fs::write(package.join("hidden.txt"), "private implementation").unwrap();
        }
        let scope = Scope {
            roots: vec![root.clone()],
            ..Scope::default()
        };
        scan(&database, &scope).unwrap();
        let conn = super::super::open_read(&database).unwrap();
        let indexed = paths(&conn);
        assert_eq!(indexed.len(), extensions.len() + 1);
        let coverage = Coverage::new(database.clone(), &scope).unwrap();
        for extension in extensions {
            let package = root.join(format!("Example.{extension}"));
            assert!(indexed.contains(&package.to_str().unwrap().to_owned()));
            assert!(!coverage.contains(&package.join("hidden.txt")));
        }
        // An explicitly selected package is still indexed as one opaque entry,
        // not mistaken for an unreadable root just because it is not enumerated.
        let package_database = fixture.0.join("package.db");
        scan(
            &package_database,
            &Scope {
                roots: vec![root.join("Example.APP")],
                ..Scope::default()
            },
        )
        .unwrap();
        let package_reader = super::super::open_read(&package_database).unwrap();
        assert_eq!(
            paths(&package_reader),
            vec![root.join("Example.APP").to_str().unwrap().to_owned()]
        );
        let nested = root.join("Example.APP").join("Sources");
        fs::create_dir(&nested).unwrap();
        let explicit = nested.join("explicit.txt");
        fs::write(&explicit, "explicit root").unwrap();
        let explicit_scope = Scope {
            roots: vec![root, nested],
            ..Scope::default()
        };
        scan(&database, &explicit_scope).unwrap();
        assert!(paths(&conn).contains(&explicit.to_str().unwrap().to_owned()));
        // Narrowing back removes the now-opaque descendant, including old rows.
        scan(&database, &scope).unwrap();
        assert!(!paths(&conn).contains(&explicit.to_str().unwrap().to_owned()));
    }

    #[test]
    fn legacy_inline_documents_do_not_accumulate_in_a_writer_batch() {
        let fixture = Fixture::new("inline-batches");
        let root = fixture.0.join("files");
        fs::create_dir(&root).unwrap();
        fs::write(root.join("first.txt"), "first searchable document").unwrap();
        fs::write(root.join("second.txt"), "second searchable document").unwrap();
        let database = fixture.0.join("index.db");
        let coverage = Coverage::new(
            database.clone(),
            &Scope {
                roots: vec![root.clone()],
                documents: true,
                ..Scope::default()
            },
        )
        .unwrap();
        let (mut conn, _lease) = open_write(&database, true).unwrap();
        begin(&mut conn).unwrap().commit().unwrap();
        let mut walk = Walk::new(&conn, &coverage);
        walk.visit(&root, true, true).unwrap();
        assert!(conn.is_autocommit());
        assert!(
            walk.pending.is_empty(),
            "each legacy document must flush rather than await a full metadata batch"
        );
        assert_eq!(paths(&conn).len(), 3);
        let documents: i64 = conn
            .query_row("SELECT count(*) FROM document", [], |row| row.get(0))
            .unwrap();
        assert_eq!(documents, 2);
    }

    #[test]
    fn scan_publishes_bounded_batches_without_holding_a_walk_transaction() {
        let fixture = Fixture::new("batches");
        let root = fixture.0.join("files");
        fs::create_dir(&root).unwrap();
        for number in 0..WRITE_BATCH + 1 {
            fs::write(root.join(format!("record-{number}.txt")), "").unwrap();
        }
        let database = fixture.0.join("index.db");
        let scope = Scope {
            roots: vec![root.clone()],
            ..Scope::default()
        };
        let coverage = Coverage::new(database.clone(), &scope).unwrap();
        let (mut conn, _lease) = open_write(&database, true).unwrap();
        begin(&mut conn).unwrap().commit().unwrap();
        let mut walk = Walk::new(&conn, &coverage);
        walk.cold = true;
        walk.visit(&root, true, true).unwrap();
        assert!(
            conn.is_autocommit(),
            "filesystem traversal must not retain a writer transaction"
        );
        let reader = super::super::open_read(&database).unwrap();
        assert_eq!(paths(&reader).len(), WRITE_BATCH);
        let searchable: i64 = reader
            .query_row(
                "SELECT count(*) FROM name_fts WHERE name_fts MATCH 'record'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert!(
            searchable >= (WRITE_BATCH - 1) as i64,
            "each committed batch must already be searchable"
        );
        assert_eq!(walk.pending.len(), 2);
        walk.flush().unwrap();
        assert_eq!(paths(&reader).len(), WRITE_BATCH + 2);
        assert!(conn.is_autocommit());
        drop(walk);
        drop(_lease);
        drop(conn);
        fs::remove_file(root.join("record-0.txt")).unwrap();
        scan(&database, &scope).unwrap();
        assert_eq!(paths(&reader).len(), WRITE_BATCH + 1);
        assert!(!paths(&reader).contains(&root.join("record-0.txt").to_str().unwrap().to_owned()));
    }
}
