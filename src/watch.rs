use super::{ScanProgressReporter, Scope};
use anyhow::Result;
use std::path::Path;

#[cfg(target_os = "macos")]
mod fsevents;
#[cfg(target_os = "macos")]
mod resume;
#[cfg(target_os = "macos")]
pub(crate) use macos::checkpoint_before_scan;
#[cfg(target_os = "macos")]
pub(crate) use resume::{can_enumerate, can_read_document};

#[derive(Clone, Copy, Debug, PartialEq, Eq, serde::Serialize)]
#[serde(tag = "event", rename_all = "snake_case")]
pub enum WatchEvent {
    /// The saved scope is committed. Clients must verify live access per hit.
    Cached,
    /// Startup replay or reconciliation is committed and search clients can connect.
    Ready,
    /// A committed change is available to existing search clients.
    Updated,
}

pub fn watch(
    database: &Path,
    scope: &Scope,
    emit: impl FnMut(WatchEvent) -> Result<()>,
) -> Result<()> {
    watch_with_progress(database, scope, None, emit)
}

pub fn watch_with_progress(
    database: &Path,
    scope: &Scope,
    progress: Option<&ScanProgressReporter>,
    emit: impl FnMut(WatchEvent) -> Result<()>,
) -> Result<()> {
    watch_with_launch_progress(database, scope, progress, false, emit)
}

#[cfg(not(target_os = "macos"))]
pub fn watch_with_launch_progress(
    _: &Path,
    _: &Scope,
    _: Option<&ScanProgressReporter>,
    _: bool,
    _: impl FnMut(WatchEvent) -> Result<()>,
) -> Result<()> {
    anyhow::bail!("live indexing currently requires macOS FSEvents");
}

#[cfg(target_os = "macos")]
mod macos {
    use super::{Path, Result, ScanProgressReporter, Scope, WatchEvent, fsevents, resume};
    use crate::index::{Coverage, apply_changes, reconcile, restrict_scope, startup_scope};
    use crate::{ScanPhase, ScanStats, absolute, open_write, platform};
    use anyhow::Context;
    use rusqlite::Connection;
    use std::{
        collections::{BTreeMap, BTreeSet},
        fs,
        path::PathBuf,
        sync::{
            Arc,
            atomic::{AtomicBool, Ordering},
            mpsc::{self, Receiver, RecvTimeoutError, SyncSender, TrySendError},
        },
        time::{Duration, Instant},
    };

    struct MaintenancePolicy {
        periodic: Duration,
        recovery_cooldown: Duration,
        persistent: bool,
        guarded_cache: bool,
    }

    const MIN_UPDATE_INTERVAL: Duration = Duration::from_millis(300);
    const QUEUE_CAPACITY: usize = 8192;
    const BATCH_SIZE: usize = 512;
    const REPLAY_LIMIT: Duration = Duration::from_secs(4);
    const MAX_PERSISTED_RECONCILIATION_AGE: Duration = Duration::from_secs(24 * 60 * 60);

    pub(crate) fn checkpoint_before_scan<'a>(
        conn: &Connection,
        coverage: &'a Coverage,
    ) -> Result<impl FnOnce(&Connection) -> Result<()> + use<'a>> {
        resume::install_invalidation(conn)?;
        let roots = configured_watches(coverage);
        let fence = resume::Journal::open(coverage, &roots)
            .and_then(|journal| Some((journal.current_id()?, journal)));
        Ok(move |conn: &Connection| {
            if let Some((cursor, journal)) = fence
                && journal.unchanged(coverage, &roots)
            {
                journal.save(conn, &coverage.scope, cursor)?;
            }
            Ok(())
        })
    }

    pub fn watch_with_launch_progress(
        database: &Path,
        scope: &Scope,
        progress: Option<&ScanProgressReporter>,
        guarded_cache: bool,
        mut emit: impl FnMut(WatchEvent) -> Result<()>,
    ) -> Result<()> {
        crate::external::check_primary_scope(scope)?;
        let _io = platform::NoMaterialization::enter()?;
        let file = absolute(database)?;
        if scope.unspecified() && !file.try_exists()? {
            anyhow::bail!(
                "no saved scope; pass --root or --allow to start an index (use --root / for the startup volume)"
            );
        }
        let (mut conn, _lease) = open_write(&file, true)
            .with_context(|| format!("open watch index {}", file.display()))?;
        let uses_saved_scope = scope.unspecified();
        let mut scope = startup_scope(&conn, scope)?;
        if uses_saved_scope {
            crate::external::retain_local_watch_scope(&mut scope)?;
        }
        crate::external::check_primary_scope(&scope)?;
        let coverage = Arc::new(Coverage::new(file, &scope)?);
        crate::external::check_primary_scope(&coverage.scope)?;
        let unchanged = guarded_cache
            && uses_saved_scope
            && crate::saved_index_scope(&conn)?.as_ref() == Some(&coverage.scope)
            && conn.query_row(
                "SELECT EXISTS(SELECT 1 FROM info WHERE key='scan')",
                [],
                |r| r.get::<_, bool>(0),
            )?;
        restrict_scope(&mut conn, &coverage)
            .context("apply watch scope before filesystem traversal")?;
        if unchanged {
            emit(WatchEvent::Cached).context("emit cached catalog event")?;
        }
        // Periodic checks cover silently lost notifications, non-journaling
        // volumes, and directories we could not read during a previous pass.
        let policy = MaintenancePolicy {
            periodic: Duration::from_secs(30 * 60),
            recovery_cooldown: Duration::from_secs(30),
            persistent: true,
            guarded_cache,
        };
        resume::install_invalidation(&conn)?;
        maintain(&mut conn, coverage, policy, progress, start_stream, emit)
    }

    struct Subscription<S> {
        sink: Arc<Sink>,
        receiver: Receiver<Event>,
        _stream: S,
        journal: Option<resume::Journal>,
        cursor: u64,
    }

    struct History {
        targets: BTreeMap<PathBuf, bool>,
        cursor: u64,
        overlap: Option<String>,
    }

    impl<S> Subscription<S> {
        fn start(
            conn: &mut Connection,
            coverage: &Arc<Coverage>,
            persistent: bool,
            allow_resume: bool,
            start: &impl Fn(&Arc<Sink>, Option<(&resume::Journal, u64)>) -> Result<S>,
        ) -> Result<(Self, bool)> {
            let roots = configured_watches(coverage);
            let journal = persistent
                .then(|| resume::Journal::open(coverage, &roots))
                .flatten();
            if let Some(journal) = journal {
                let previous = if allow_resume {
                    journal.load(conn, &coverage.scope)?
                } else {
                    None
                };
                if let Some(cursor) = previous.or_else(|| journal.current_id()) {
                    let (sink, receiver) = Sink::new(coverage, roots.clone(), true);
                    match start(&sink, Some((&journal, cursor))) {
                        Ok(stream) => {
                            return Ok((
                                Self {
                                    sink,
                                    receiver,
                                    _stream: stream,
                                    journal: Some(journal),
                                    cursor,
                                },
                                previous.is_some(),
                            ));
                        }
                        Err(error) => {
                            eprintln!("lumen watch: could not open volume journal: {error:#}")
                        }
                    }
                }
            }

            let (sink, receiver) = Sink::new(coverage, roots, false);
            let stream = match start(&sink, None) {
                Ok(stream) => stream,
                Err(error) => {
                    if persistent {
                        resume::invalidate(conn)?;
                        resume::verify_access(conn, Some(&sink.roots))?;
                    }
                    return Err(error);
                }
            };
            Ok((
                Self {
                    sink,
                    receiver,
                    _stream: stream,
                    journal: None,
                    cursor: 0,
                },
                false,
            ))
        }

        fn replay(&self) -> Option<History> {
            let deadline = Instant::now() + REPLAY_LIMIT;
            let mut targets = BTreeMap::new();
            let mut events = BTreeSet::new();
            let mut cursor = self.cursor;
            // Build a bounded set before applying it. Incomplete history,
            // topology changes and queue overflow all require reconciliation.
            for _ in 0..QUEUE_CAPACITY {
                if self.sink.lost.load(Ordering::Acquire) {
                    return None;
                }
                let timeout = deadline.checked_duration_since(Instant::now())?;
                match self.receiver.recv_timeout(timeout).ok()? {
                    Event::Change(change) if !change.rearm && !change.uncertain => {
                        events.insert((change.id, change.path.clone(), change.subtree));
                        add_target(&mut targets, change)
                    }
                    Event::Checkpoint { id, history_done } => {
                        cursor = cursor.max(id);
                        if history_done && !self.sink.lost.load(Ordering::Acquire) {
                            return Some(History {
                                targets,
                                cursor,
                                overlap: resume::replay_overlap(cursor, &events),
                            });
                        }
                    }
                    _ => return None,
                }
            }
            None
        }

        fn save(&mut self, conn: &Connection, cursor: u64) -> Result<()> {
            if let Some(journal) = &self.journal {
                journal.save(conn, &self.sink.coverage.scope, cursor)?;
                self.cursor = cursor;
            }
            Ok(())
        }
    }

    fn maintain<S>(
        conn: &mut Connection,
        mut coverage: Arc<Coverage>,
        policy: MaintenancePolicy,
        progress: Option<&ScanProgressReporter>,
        start: impl Fn(&Arc<Sink>, Option<(&resume::Journal, u64)>) -> Result<S>,
        mut emit: impl FnMut(WatchEvent) -> Result<()>,
    ) -> Result<()> {
        let MaintenancePolicy {
            periodic,
            recovery_cooldown,
            persistent,
            guarded_cache,
        } = policy;
        let (mut sub, attempt_resume) =
            Subscription::start(conn, &coverage, persistent, true, &start)?;
        let mut resumed = false;
        if attempt_resume
            && let Some(History {
                targets,
                cursor,
                overlap,
            }) = sub.replay()
        {
            let mut had_access_errors = false;
            let target_count = targets.len();
            let mut visited = 0;
            let repeated = cursor == sub.cursor
                && overlap
                    .as_deref()
                    .map(|overlap| resume::already_replayed(conn, overlap))
                    .transpose()?
                    .unwrap_or(false);
            if !targets.is_empty() && !repeated {
                let (stats, _) = apply_changes(conn, &coverage, targets)
                    .context("commit historical filesystem changes")?;
                report_unreadable(&stats);
                had_access_errors = stats.entries_unreadable != 0;
                visited = stats.entries_visited;
            }
            if resume::verify_access(conn, Some(&sub.sink.roots))?
                && !had_access_errors
                && sub
                    .journal
                    .as_ref()
                    .is_some_and(|journal| journal.unchanged(&coverage, &sub.sink.roots))
                && !sub.sink.lost.load(Ordering::Acquire)
            {
                sub.save(conn, cursor)?;
                resume::remember_replay(conn, overlap)?;
                if guarded_cache && progress.is_some() {
                    eprintln!(
                        "lumen watch: recovered {target_count} history targets, visited {visited} entries"
                    );
                }
                if let Some(progress) = progress {
                    // No scanner ran to close the preparing phase. Otherwise
                    // its heartbeat can make a healthy watcher appear busy.
                    progress.phase(ScanPhase::Done, visited, None);
                }
                resumed = true;
            }
        }
        if !resumed {
            if guarded_cache {
                let reason = if attempt_resume {
                    "history incomplete or uncertain"
                } else {
                    "no matching journal checkpoint"
                };
                eprintln!("lumen watch: {reason}; reconciling the configured scope");
            }
            if persistent {
                resume::invalidate(conn)?;
                if attempt_resume {
                    coverage = Arc::new(coverage.refreshed()?);
                    restrict_scope(conn, &coverage).context("apply refreshed watch scope")?;
                    (sub, _) = Subscription::start(conn, &coverage, persistent, false, &start)?;
                }
            }
            if persistent && coverage.scope.documents {
                resume::verify_access(conn, None)?;
            }
            reconcile_startup(conn, &coverage, &mut sub, progress)?;
        } else {
            // Existing catalogs can migrate without forcing a full walk.
            crate::name_fast::install_han_ending(conn);
        }
        emit(WatchEvent::Ready).context("emit watch ready event")?;

        let mut last_reconciled = Instant::now();
        let mut last_emitted = Instant::now();
        // Restarts cannot defer the repair of a silently missed event forever.
        // The age bound is separate from the normal in-session periodic check.
        let mut pending_recovery = persistent
            && resumed
            && crate::index::reconciliation_overdue(conn, MAX_PERSISTED_RECONCILIATION_AGE)?;
        let mut pending_update = false;
        loop {
            let interval = if pending_recovery {
                recovery_cooldown
            } else {
                periodic
            };
            let mut wait = interval.saturating_sub(last_reconciled.elapsed());
            if pending_update {
                wait = wait.min(MIN_UPDATE_INTERVAL.saturating_sub(last_emitted.elapsed()));
            }
            let first = match sub.receiver.recv_timeout(wait) {
                Ok(event) => Some(event),
                Err(RecvTimeoutError::Timeout) => None,
                Err(RecvTimeoutError::Disconnected) => {
                    anyhow::bail!("filesystem notification queue closed")
                }
            };
            let mut targets = BTreeMap::new();
            let mut rearm = false;
            let mut cursor = sub.cursor;
            for event in first
                .into_iter()
                .chain(sub.receiver.try_iter().take(BATCH_SIZE - 1))
            {
                match event {
                    Event::Change(change) => {
                        rearm |= change.rearm;
                        add_target(&mut targets, change);
                    }
                    Event::Checkpoint { id, .. } => cursor = cursor.max(id),
                    Event::Lost => {}
                }
            }
            if sub.sink.lost.swap(false, Ordering::AcqRel) {
                if persistent {
                    resume::invalidate(conn)?;
                }
                if !pending_recovery {
                    eprintln!(
                        "lumen watch: filesystem notifications lost; checking configured roots"
                    );
                }
                pending_recovery = true;
            }
            let full = rearm
                || last_reconciled.elapsed() >= periodic
                || pending_recovery && last_reconciled.elapsed() >= recovery_cooldown;
            if full {
                if persistent {
                    resume::invalidate(conn)?;
                }
                // Subscribe with a fresh queue before scanning. No cursor from
                // the stream that lost events can advance the new checkpoint.
                coverage = Arc::new(coverage.refreshed()?);
                restrict_scope(conn, &coverage).context("apply refreshed watch scope")?;
                (sub, _) = Subscription::start(conn, &coverage, persistent, false, &start)?;
                reconcile_startup(conn, &coverage, &mut sub, None)?;
                last_reconciled = Instant::now();
                pending_recovery = false;
                pending_update = true;
            } else {
                if !targets.is_empty() {
                    let (stats, changed) = apply_changes(conn, &coverage, targets)
                        .context("commit filesystem changes to watch index")?;
                    report_unreadable(&stats);
                    pending_recovery |= stats.entries_unreadable != 0;
                    pending_update |= changed;
                }
                if cursor > sub.cursor
                    && !pending_recovery
                    && !sub.sink.lost.load(Ordering::Acquire)
                {
                    sub.save(conn, cursor)?;
                }
            }
            if pending_update && last_emitted.elapsed() >= MIN_UPDATE_INTERVAL {
                emit(WatchEvent::Updated).context("emit watch update event")?;
                last_emitted = Instant::now();
                pending_update = false;
            }
        }
    }

    fn add_target(targets: &mut BTreeMap<PathBuf, bool>, change: Change) {
        targets
            .entry(change.path)
            .and_modify(|subtree| *subtree |= change.subtree)
            .or_insert(change.subtree);
    }

    fn reconcile_startup<S>(
        conn: &mut Connection,
        coverage: &Coverage,
        sub: &mut Subscription<S>,
        progress: Option<&ScanProgressReporter>,
    ) -> Result<()> {
        // A seed is captured before subscribing and scanning. Events that
        // arrive during the walk remain queued and are replayable after a crash.
        let stats = reconcile(conn, coverage, false, progress)
            .context("reconcile configured watch roots")?;
        report_unreadable(&stats);
        if !sub.sink.lost.load(Ordering::Acquire)
            && sub
                .journal
                .as_ref()
                .is_some_and(|journal| journal.unchanged(coverage, &sub.sink.roots))
        {
            sub.save(conn, sub.cursor)?;
        } else {
            sub.journal = None;
        }
        Ok(())
    }

    fn report_unreadable(stats: &ScanStats) {
        if stats.entries_unreadable != 0 {
            eprintln!(
                "lumen watch: {} filesystem entries could not be checked",
                stats.entries_unreadable
            );
        }
    }

    fn start_stream(
        sink: &Arc<Sink>,
        replay: Option<(&resume::Journal, u64)>,
    ) -> Result<Option<fsevents::Stream>> {
        if let Some((journal, cursor)) = replay {
            return fsevents::Stream::start(&journal.paths(), sink, Some((journal.device, cursor)))
                .map(Some);
        }
        let roots = sink
            .roots
            .iter()
            .map(|root| existing_directory(root))
            .collect();
        let paths = outermost(roots);
        if paths.is_empty() {
            return Ok(None);
        }
        fsevents::Stream::start(&paths, sink, None).map(Some)
    }

    fn configured_watches(coverage: &Coverage) -> Vec<PathBuf> {
        let scope = &coverage.scope;
        let mut paths = BTreeSet::new();
        for root in &scope.roots {
            if scope.allow.is_empty() {
                if coverage.allows(root) {
                    paths.insert(root.clone());
                }
                continue;
            }
            for allow in &scope.allow {
                let path = if allow.starts_with(root) {
                    allow
                } else if root.starts_with(allow) {
                    root
                } else {
                    continue;
                };
                if coverage.allows(path) {
                    paths.insert(path.clone());
                }
            }
        }
        outermost(paths)
    }

    fn outermost(paths: BTreeSet<PathBuf>) -> Vec<PathBuf> {
        paths
            .iter()
            .filter(|path| {
                !path
                    .ancestors()
                    .skip(1)
                    .any(|parent| paths.contains(parent))
            })
            .cloned()
            .collect()
    }

    fn existing_directory(root: &Path) -> PathBuf {
        let mut parents: Vec<_> = root.ancestors().collect();
        let mut usable = Path::new("/");
        while let Some(path) = parents.pop() {
            if !fs::symlink_metadata(path).is_ok_and(|meta| {
                meta.is_dir() && platform::availability(path, &meta) != "placeholder"
            }) {
                break;
            }
            usable = path;
        }
        usable.to_path_buf()
    }

    struct Change {
        id: u64,
        path: PathBuf,
        subtree: bool,
        rearm: bool,
        uncertain: bool,
    }

    enum Event {
        Change(Change),
        Checkpoint { id: u64, history_done: bool },
        Lost,
    }

    pub(super) struct Sink {
        sender: SyncSender<Event>,
        lost: AtomicBool,
        coverage: Arc<Coverage>,
        roots: Vec<PathBuf>,
        volume_relative: bool,
    }

    impl Sink {
        fn new(
            coverage: &Arc<Coverage>,
            roots: Vec<PathBuf>,
            volume_relative: bool,
        ) -> (Arc<Self>, Receiver<Event>) {
            let (sender, receiver) = mpsc::sync_channel(QUEUE_CAPACITY);
            (
                Arc::new(Self {
                    sender,
                    lost: AtomicBool::new(false),
                    coverage: coverage.clone(),
                    roots,
                    volume_relative,
                }),
                receiver,
            )
        }

        pub(super) fn lost(&self) {
            self.lost.store(true, Ordering::Release);
            // A full queue already wakes the worker. A native loss notice may
            // arrive on an idle stream: queue a sentinel to wake it in that case.
            let _ = self.sender.try_send(Event::Lost);
        }

        pub(super) fn checkpoint(&self, id: u64, history_done: bool) {
            if self.volume_relative {
                self.send(Event::Checkpoint { id, history_done });
            }
        }

        pub(super) fn native_change(
            &self,
            path: &Path,
            id: u64,
            subtree: bool,
            rearm: bool,
            uncertain: bool,
        ) -> bool {
            // Device callbacks provide paths relative to the Data volume;
            // host callbacks can instead use its physical mount prefix.
            let logical;
            let path = if let Ok(rest) = path.strip_prefix("/System/Volumes/Data") {
                logical = Path::new("/").join(rest);
                &logical
            } else if self.volume_relative && !path.is_absolute() {
                logical = Path::new("/").join(path);
                &logical
            } else {
                path
            };
            if !path.is_absolute() {
                self.lost();
                return false;
            }
            let structural = subtree || rearm;
            let below_watch = self.roots.iter().any(|root| path.starts_with(root));
            let above_watch = structural && self.roots.iter().any(|root| root.starts_with(path));
            if !below_watch && !above_watch {
                return false;
            }
            let scan_roots = &self.coverage.scope.roots;
            if scan_roots.iter().any(|root| path.starts_with(root)) && self.coverage.allows(path) {
                self.change(
                    path,
                    id,
                    subtree,
                    rearm || above_watch && !below_watch,
                    uncertain,
                );
                true
            } else if above_watch {
                let mut sent = false;
                for root in scan_roots {
                    if root.starts_with(path) && self.coverage.allows(root) {
                        self.change(root, id, true, true, uncertain);
                        sent = true;
                    }
                }
                sent
            } else {
                false
            }
        }

        fn change(&self, path: &Path, id: u64, subtree: bool, rearm: bool, uncertain: bool) {
            self.send(Event::Change(Change {
                id,
                path: path.into(),
                subtree,
                rearm,
                uncertain,
            }));
        }

        fn send(&self, event: Event) {
            if let Err(TrySendError::Full(_)) = self.sender.try_send(event) {
                self.lost.store(true, Ordering::Release);
            }
        }
    }
    #[cfg(test)]
    mod tests {
        use super::*;
        use std::{
            cell::RefCell,
            ffi::{CStr, OsStr},
            os::unix::ffi::OsStrExt,
        };

        struct TestDirectory(PathBuf);

        impl TestDirectory {
            fn new() -> Self {
                let mut template = *b"/tmp/lumen-access-XXXXXX\0";
                let path = unsafe { libc::mkdtemp(template.as_mut_ptr().cast()) };
                assert!(!path.is_null());
                Self(
                    fs::canonicalize(PathBuf::from(OsStr::from_bytes(
                        unsafe { CStr::from_ptr(path) }.to_bytes(),
                    )))
                    .unwrap(),
                )
            }
        }

        impl Drop for TestDirectory {
            fn drop(&mut self) {
                use std::os::unix::fs::PermissionsExt;
                let _ = fs::set_permissions(
                    self.0.join("root/private"),
                    fs::Permissions::from_mode(0o700),
                );
                let _ = fs::remove_dir_all(&self.0);
            }
        }

        #[test]
        fn cached_resume_rechecks_access_without_filesystem_events() {
            use std::os::unix::fs::PermissionsExt;
            if unsafe { libc::geteuid() } == 0 {
                return;
            }
            let dir = TestDirectory::new();
            let root = dir.0.join("root");
            let private = root.join("private");
            fs::create_dir_all(&private).unwrap();
            fs::write(private.join("secret.txt"), "private cached document").unwrap();
            let db = absolute(&dir.0.join("index.sqlite")).unwrap();
            let (mut conn, _lease) = open_write(&db, true).unwrap();
            let coverage = Arc::new(
                Coverage::new(
                    db,
                    &Scope {
                        roots: vec![root],
                        ..Scope::default()
                    },
                )
                .unwrap(),
            );
            resume::install_invalidation(&conn).unwrap();
            let policy = || MaintenancePolicy {
                periodic: Duration::from_secs(60),
                recovery_cooldown: Duration::from_millis(80),
                persistent: true,
                guarded_cache: true,
            };
            let start = |sink: &Arc<Sink>, replay: Option<(&resume::Journal, u64)>| {
                if let Some((_, cursor)) = replay {
                    sink.send(Event::Checkpoint {
                        id: cursor,
                        history_done: true,
                    });
                }
                Ok(())
            };
            let ready = |event| {
                assert!(matches!(event, WatchEvent::Ready));
                anyhow::bail!("ready")
            };
            maintain(&mut conn, coverage.clone(), policy(), None, start, ready).unwrap_err();
            assert_eq!(
                crate::search(&conn, "secret", crate::Mode::Name, 20, None)
                    .unwrap()
                    .len(),
                1
            );
            assert!(
                resume::Journal::open(&coverage, &configured_watches(&coverage))
                    .unwrap()
                    .load(&conn, &coverage.scope)
                    .unwrap()
                    .is_some()
            );
            fs::set_permissions(&private, fs::Permissions::from_mode(0o0)).unwrap();
            maintain(&mut conn, coverage, policy(), None, start, ready).unwrap_err();
            assert!(
                crate::search(&conn, "secret", crate::Mode::Name, 20, None)
                    .unwrap()
                    .is_empty()
            );
        }

        #[test]
        fn unreadable_live_entries_schedule_recovery() {
            use std::os::unix::fs::PermissionsExt;
            if unsafe { libc::geteuid() } == 0 {
                return;
            }
            let dir = TestDirectory::new();
            let root = dir.0.join("root");
            let private = root.join("private");
            fs::create_dir_all(&private).unwrap();
            fs::write(private.join("secret.txt"), "retained entry").unwrap();
            let db = absolute(&dir.0.join("index.sqlite")).unwrap();
            let (mut conn, _lease) = open_write(&db, true).unwrap();
            let coverage = Arc::new(
                Coverage::new(
                    db.clone(),
                    &Scope {
                        roots: vec![root],
                        ..Scope::default()
                    },
                )
                .unwrap(),
            );
            let sink = RefCell::<Option<Arc<Sink>>>::new(None);
            let periodic = Duration::from_secs(5);
            let started = Instant::now();
            let mut updates = 0;
            let result = maintain(
                &mut conn,
                coverage,
                MaintenancePolicy {
                    periodic,
                    // Leave time for Updated to restore access before recovery.
                    recovery_cooldown: MIN_UPDATE_INTERVAL * 2,
                    persistent: false,
                    guarded_cache: false,
                },
                None,
                |s, _| {
                    *sink.borrow_mut() = Some(s.clone());
                    Ok(())
                },
                |event| {
                    match event {
                        WatchEvent::Ready => {
                            fs::set_permissions(&private, fs::Permissions::from_mode(0o0))?;
                            sink.borrow()
                                .as_ref()
                                .unwrap()
                                .change(&private, 0, true, false, false);
                        }
                        WatchEvent::Updated => {
                            updates += 1;
                            let reader = crate::open_read(&db)?;
                            let hits =
                                crate::search(&reader, "secret", crate::Mode::Name, 20, None)?;
                            if updates == 1 {
                                assert!(hits.is_empty());
                                fs::set_permissions(&private, fs::Permissions::from_mode(0o700))?;
                            } else {
                                assert_eq!(hits.len(), 1);
                                assert!(
                                    started.elapsed() < periodic,
                                    "unreadable entries did not accelerate recovery"
                                );
                                anyhow::bail!("recovered");
                            }
                        }
                        WatchEvent::Cached => unreachable!(),
                    }
                    Ok(())
                },
            );
            assert_eq!(result.unwrap_err().root_cause().to_string(), "recovered");
            assert_eq!(updates, 2);
        }

        #[test]
        fn incremental_targets_and_missed_event_recovery() {
            check_recovery(true);
        }

        #[test]
        fn periodic_reconciliation_catches_silent_loss() {
            check_recovery(false);
        }

        fn check_recovery(report_loss: bool) {
            let mut template = *b"/tmp/lumen-recovery-XXXXXX\0";
            // The two recovery cases run in the same process and may start
            // in the same clock tick. Allocate the directory atomically.
            let path = unsafe { libc::mkdtemp(template.as_mut_ptr().cast()) };
            assert!(
                !path.is_null(),
                "mkdtemp: {}",
                std::io::Error::last_os_error()
            );
            let dir = PathBuf::from(OsStr::from_bytes(
                unsafe { CStr::from_ptr(path) }.to_bytes(),
            ));
            struct Cleanup(PathBuf);
            impl Drop for Cleanup {
                fn drop(&mut self) {
                    let _ = fs::remove_dir_all(&self.0);
                }
            }
            let _cleanup = Cleanup(dir.clone());
            let root = dir.join("root");
            fs::create_dir(&root).unwrap();
            let db = absolute(&dir.join("test.sqlite")).unwrap();
            let (mut conn, _lease) = open_write(&db, true).unwrap();
            let coverage = Arc::new(
                Coverage::new(
                    db.clone(),
                    &Scope {
                        roots: vec![root.clone()],
                        ..Scope::default()
                    },
                )
                .unwrap(),
            );
            let target = absolute(&root.join("delivered.txt")).unwrap();
            let missed = absolute(&root.join("missed.txt")).unwrap();
            let sink = RefCell::<Option<Arc<Sink>>>::new(None);
            let periodic = Duration::from_millis(if report_loss { 2500 } else { 500 });
            let policy = MaintenancePolicy {
                periodic,
                recovery_cooldown: Duration::from_millis(80),
                persistent: false,
                guarded_cache: false,
            };
            let mut updates = 0;
            let started = Instant::now();
            let result = maintain(
                &mut conn,
                coverage,
                policy,
                None,
                |s, _| {
                    *sink.borrow_mut() = Some(s.clone());
                    Ok(())
                },
                |event| {
                    let sink = sink.borrow();
                    let sink = sink.as_ref().unwrap();
                    match event {
                        WatchEvent::Cached => {
                            unreachable!("synthetic watcher has no startup client")
                        }
                        WatchEvent::Ready => {
                            fs::write(&target, "this notification is delivered")?;
                            fs::write(&missed, "there is no notification for this path")?;
                            sink.change(&target, 0, false, false, false);
                        }
                        WatchEvent::Updated => {
                            updates += 1;
                            let db = crate::open_read(&db)?;
                            let names = |s| crate::search(&db, s, crate::Mode::Name, 20, None);
                            assert_eq!(names("delivered")?.len(), 1);
                            if updates == 1 {
                                assert!(
                                    names("missed")?.is_empty(),
                                    "file events changed an unaffected path"
                                );
                                if report_loss {
                                    sink.lost();
                                }
                            } else {
                                assert_eq!(names("missed")?.len(), 1);
                                if report_loss {
                                    assert!(
                                        started.elapsed() < periodic,
                                        "lost-event notice did not accelerate reconciliation"
                                    );
                                }
                                anyhow::bail!("test complete");
                            }
                        }
                    }
                    Ok(())
                },
            );
            assert_eq!(
                result.unwrap_err().root_cause().to_string(),
                "test complete"
            );
            assert_eq!(updates, 2);
        }
    }
}

#[cfg(target_os = "macos")]
pub use macos::watch_with_launch_progress;
