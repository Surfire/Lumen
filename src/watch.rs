use super::Scope;
use anyhow::Result;
use std::path::Path;

#[cfg(target_os = "macos")]
mod fsevents;

#[derive(Clone, Copy, Debug, PartialEq, Eq, serde::Serialize)]
#[serde(tag = "event", rename_all = "snake_case")]
pub enum WatchEvent {
    /// The initial reconciliation is committed and search clients can connect.
    Ready,
    /// A committed change is available to existing search clients.
    Updated,
}

#[cfg(not(target_os = "macos"))]
pub fn watch(_: &Path, _: &Scope, _: impl FnMut(WatchEvent) -> Result<()>) -> Result<()> {
    anyhow::bail!("live indexing currently requires macOS FSEvents");
}

#[cfg(target_os = "macos")]
mod macos {
    use super::{Path, Result, Scope, WatchEvent, fsevents};
    use crate::index::{Coverage, apply_changes, reconcile, restrict_scope, startup_scope};
    use crate::{ScanStats, absolute, open_write, platform};
    use anyhow::Context;
    use rusqlite::Connection;
    use std::{
        collections::{BTreeMap, BTreeSet},
        fs,
        path::PathBuf,
        sync::{
            Arc,
            atomic::{AtomicBool, Ordering},
            mpsc::{self, RecvTimeoutError, SyncSender, TrySendError},
        },
        time::{Duration, Instant},
    };

    #[derive(Clone, Copy)]
    struct Timing {
        periodic: Duration,
        recovery_cooldown: Duration,
    }

    const MIN_UPDATE_INTERVAL: Duration = Duration::from_millis(300);
    const QUEUE_CAPACITY: usize = 8192;
    const BATCH_SIZE: usize = 512;

    pub fn watch(
        database: &Path,
        scope: &Scope,
        emit: impl FnMut(WatchEvent) -> Result<()>,
    ) -> Result<()> {
        let _io = platform::NoMaterialization::enter()?;
        let file = absolute(database)?;
        if scope.unspecified() && !file.try_exists()? {
            anyhow::bail!(
                "no saved scope; pass --root or --allow to start an index (use --root / for the startup volume)"
            );
        }
        let (mut conn, _lease) = open_write(&file, true)
            .with_context(|| format!("open watch index {}", file.display()))?;
        let scope = startup_scope(&conn, scope)?;
        let coverage = Arc::new(Coverage::new(file, &scope)?);
        restrict_scope(&mut conn, &coverage)
            .context("apply watch scope before filesystem traversal")?;
        // Periodic checks cover silently lost notifications, non-journaling
        // volumes, and directories we could not read during a previous pass.
        let timing = Timing {
            periodic: Duration::from_secs(30 * 60),
            recovery_cooldown: Duration::from_secs(30),
        };
        maintain(&mut conn, coverage, timing, start_stream, emit)
    }

    fn maintain<S>(
        conn: &mut Connection,
        mut coverage: Arc<Coverage>,
        timing: Timing,
        start: impl Fn(&Arc<Sink>) -> Result<S>,
        mut emit: impl FnMut(WatchEvent) -> Result<()>,
    ) -> Result<()> {
        let roots = configured_watches(&coverage);
        let (sender, receiver) = mpsc::sync_channel(QUEUE_CAPACITY);
        let sink = Arc::new(Sink {
            sender,
            lost: AtomicBool::new(false),
            coverage: coverage.clone(),
            roots,
        });
        let mut sink = sink;
        let mut _stream = start(&sink).context("start filesystem notifications")?;

        // Subscribe first, then reconcile. Changes during this pass are queued
        // independently on the FSEvents dispatch queue, even on a large volume.
        let stats = reconcile(conn, &coverage, false).context("startup index reconciliation")?;
        report_unreadable(&stats);
        emit(WatchEvent::Ready).context("emit watch ready event")?;

        let mut last_reconciled = Instant::now();
        let mut last_emitted = last_reconciled;
        let mut pending_recovery = false;
        let mut pending_update = false;
        loop {
            let interval = if pending_recovery {
                timing.recovery_cooldown
            } else {
                timing.periodic
            };
            let mut wait = interval.saturating_sub(last_reconciled.elapsed());
            if pending_update {
                wait = wait.min(MIN_UPDATE_INTERVAL.saturating_sub(last_emitted.elapsed()));
            }
            let first = match receiver.recv_timeout(wait) {
                Ok(change) => Some(change),
                Err(RecvTimeoutError::Timeout) => None,
                Err(RecvTimeoutError::Disconnected) => {
                    anyhow::bail!("filesystem notification queue closed")
                }
            };
            let mut targets = BTreeMap::new();
            let mut rearm = false;
            for change in first
                .into_iter()
                .chain(receiver.try_iter().take(BATCH_SIZE - 1))
            {
                if change.path.as_os_str().is_empty() {
                    continue;
                }
                rearm |= change.rearm;
                targets
                    .entry(change.path)
                    .and_modify(|subtree| *subtree |= change.subtree)
                    .or_insert(change.subtree);
            }
            if sink.lost.swap(false, Ordering::AcqRel) && !pending_recovery {
                eprintln!("lumen watch: filesystem notifications lost; checking configured roots");
                pending_recovery = true;
            }
            let mut full = last_reconciled.elapsed() >= timing.periodic
                || pending_recovery && last_reconciled.elapsed() >= timing.recovery_cooldown;
            if rearm || full {
                // A watched root can move even if its textual path still
                // exists. Refresh its actual spelling and overlap the streams.
                let refreshed = Arc::new(coverage.refreshed()?);
                let scope_changed = refreshed.scope != coverage.scope;
                let replacement = if scope_changed {
                    Arc::new(Sink {
                        sender: sink.sender.clone(),
                        lost: AtomicBool::new(false),
                        coverage: refreshed.clone(),
                        roots: configured_watches(&refreshed),
                    })
                } else {
                    sink.clone()
                };
                match start(&replacement) {
                    Ok(stream) => {
                        _stream = stream;
                        sink = replacement;
                        coverage = refreshed;
                        if scope_changed {
                            restrict_scope(conn, &coverage)
                                .context("apply refreshed watch scope")?;
                            full = true;
                        }
                    }
                    Err(error) => eprintln!(
                        "lumen watch: could not renew filesystem notifications: {error:#}"
                    ),
                };
            }
            if full {
                let stats = reconcile(conn, &coverage, false)
                    .context("reconcile configured watch roots")?;
                report_unreadable(&stats);
                last_reconciled = Instant::now();
                pending_recovery = false;
                pending_update = true;
            } else if !targets.is_empty() {
                let (stats, changed) = apply_changes(conn, &coverage, targets)
                    .context("commit filesystem changes to watch index")?;
                report_unreadable(&stats);
                pending_update |= changed;
            }
            if pending_update && last_emitted.elapsed() >= MIN_UPDATE_INTERVAL {
                emit(WatchEvent::Updated).context("emit watch update event")?;
                last_emitted = Instant::now();
                pending_update = false;
            }
        }
    }

    fn report_unreadable(stats: &ScanStats) {
        if stats.entries_unreadable != 0 {
            eprintln!(
                "lumen watch: {} filesystem entries could not be checked",
                stats.entries_unreadable
            );
        }
    }

    fn start_stream(sink: &Arc<Sink>) -> Result<Option<fsevents::Stream>> {
        let roots = sink
            .roots
            .iter()
            .map(|root| existing_directory(root))
            .collect();
        let paths = outermost(roots);
        if paths.is_empty() {
            return Ok(None);
        }
        fsevents::Stream::start(&paths, sink).map(Some)
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
        path: PathBuf,
        subtree: bool,
        rearm: bool,
    }

    pub(super) struct Sink {
        sender: SyncSender<Change>,
        lost: AtomicBool,
        coverage: Arc<Coverage>,
        roots: Vec<PathBuf>,
    }

    impl Sink {
        pub(super) fn lost(&self) {
            self.lost.store(true, Ordering::Release);
            // A full queue already wakes the worker. A native loss notice may
            // arrive on an idle stream: queue a sentinel to wake it in that case.
            let _ = self.sender.try_send(Change {
                path: PathBuf::new(),
                subtree: false,
                rearm: false,
            });
        }

        pub(super) fn change(&self, path: &Path, subtree: bool, rearm: bool) {
            // Events on the startup data volume may use its physical path.
            // The index itself uses the logical path through the APFS firmlinks.
            let logical;
            let path = if let Ok(rest) = path.strip_prefix("/System/Volumes/Data") {
                logical = Path::new("/").join(rest);
                &logical
            } else {
                path
            };
            if !path.is_absolute() {
                self.lost();
                return;
            }
            let structural = subtree || rearm;
            let below_watch = self.roots.iter().any(|root| path.starts_with(root));
            let above_watch = structural && self.roots.iter().any(|root| root.starts_with(path));
            if !below_watch && !above_watch {
                return;
            }
            let scan_roots = &self.coverage.scope.roots;
            if scan_roots.iter().any(|root| path.starts_with(root)) && self.coverage.allows(path) {
                self.send(path, subtree, rearm || above_watch && !below_watch);
            } else if above_watch {
                for root in scan_roots {
                    if root.starts_with(path) && self.coverage.allows(root) {
                        self.send(root, true, true);
                    }
                }
            }
        }

        fn send(&self, path: &Path, subtree: bool, rearm: bool) {
            if let Err(TrySendError::Full(_)) = self.sender.try_send(Change {
                path: path.into(),
                subtree,
                rearm,
            }) {
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
            let timing = Timing {
                periodic: Duration::from_millis(if report_loss { 2500 } else { 500 }),
                recovery_cooldown: Duration::from_millis(80),
            };
            let mut updates = 0;
            let started = Instant::now();
            let result = maintain(
                &mut conn,
                coverage,
                timing,
                |s| {
                    *sink.borrow_mut() = Some(s.clone());
                    Ok(())
                },
                |event| {
                    let sink = sink.borrow();
                    let sink = sink.as_ref().unwrap();
                    match event {
                        WatchEvent::Ready => {
                            fs::write(&target, "this notification is delivered")?;
                            fs::write(&missed, "there is no notification for this path")?;
                            sink.change(&target, false, false);
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
                                        started.elapsed() < timing.periodic,
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
pub use macos::watch;
