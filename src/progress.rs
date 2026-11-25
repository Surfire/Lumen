use serde::Serialize;
use std::{
    io,
    sync::{
        Arc,
        atomic::{AtomicU64, Ordering},
        mpsc::{self, RecvTimeoutError, Sender},
    },
    thread::{self, JoinHandle},
    time::{Duration, Instant},
};

const INTERVAL: Duration = Duration::from_millis(250);
const ETA_MIN_INTERVAL: Duration = Duration::from_millis(500);

#[derive(Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ScanPhase {
    Preparing,
    Scanning,
    Finalizing,
    Done,
}

#[derive(Serialize)]
pub struct ScanProgress {
    pub event: &'static str,
    pub phase: ScanPhase,
    pub entries: u64,
    pub elapsed_ms: u128,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub entries_per_second: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub estimated_total: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub eta_seconds: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub estimate_basis: Option<&'static str>,
}

struct Phase {
    stage: ScanPhase,
    at: Instant,
    entries: u64,
    total: Option<u64>,
}

/// A throttled, independent progress stream for one initial scan or refresh.
/// The scanner sends phase boundaries and publishes a counter periodically.
pub struct ScanProgressReporter {
    count: Arc<AtomicU64>,
    phases: Option<Sender<Phase>>,
    worker: Option<JoinHandle<()>>,
}

impl ScanProgressReporter {
    pub fn start(
        mut write: impl FnMut(ScanProgress) -> io::Result<()> + Send + 'static,
    ) -> io::Result<Self> {
        let started = Instant::now();
        let (phases, receiver) = mpsc::channel();
        let count = Arc::new(AtomicU64::new(0));
        let published = count.clone();
        let worker = thread::Builder::new()
            .name("lumen-progress".into())
            .spawn(move || {
                let mut phase = Phase {
                    stage: ScanPhase::Preparing,
                    at: started,
                    entries: 0,
                    total: None,
                };
                let mut now = started;
                let mut entries = 0;
                let mut elapsed_ms = 0;
                loop {
                    elapsed_ms = elapsed_ms.max(now.duration_since(started).as_millis());
                    let seconds = now.saturating_duration_since(phase.at).as_secs_f64();
                    let rate = (phase.stage == ScanPhase::Scanning && seconds > 0.0 && entries > 0)
                        .then(|| entries as f64 / seconds);
                    let total = phase
                        .total
                        .filter(|&target| phase.stage != ScanPhase::Scanning || target > entries);
                    let eta_seconds = match (phase.stage, total, rate) {
                        (ScanPhase::Done, _, _) => Some(0),
                        (ScanPhase::Scanning, Some(total), Some(rate))
                            if seconds >= ETA_MIN_INTERVAL.as_secs_f64() =>
                        {
                            Some(((total - entries) as f64 / rate).ceil() as u64)
                        }
                        _ => None,
                    };
                    if write(ScanProgress {
                        event: "progress",
                        phase: phase.stage,
                        entries,
                        elapsed_ms,
                        entries_per_second: rate,
                        estimated_total: total,
                        eta_seconds,
                        estimate_basis: total.map(|_| {
                            if phase.stage == ScanPhase::Scanning {
                                "previous_scan"
                            } else {
                                "scanned"
                            }
                        }),
                    })
                    .is_err()
                        || phase.stage == ScanPhase::Done
                    {
                        return;
                    }
                    match receiver.recv_timeout(INTERVAL) {
                        Ok(next) => {
                            phase = next;
                            entries = entries.max(phase.entries);
                            now = phase.at;
                        }
                        Err(RecvTimeoutError::Timeout) => {
                            if phase.stage == ScanPhase::Scanning {
                                entries = entries.max(published.load(Ordering::Relaxed));
                            }
                            now = Instant::now();
                        }
                        Err(RecvTimeoutError::Disconnected) => return,
                    }
                }
            })?;
        Ok(Self {
            count,
            phases: Some(phases),
            worker: Some(worker),
        })
    }

    pub(super) fn entries(&self, entries: u64) {
        self.count.store(entries, Ordering::Relaxed);
    }

    pub(super) fn phase(&self, stage: ScanPhase, entries: u64, total: Option<u64>) {
        if let Some(phases) = &self.phases {
            let _ = phases.send(Phase {
                stage,
                at: Instant::now(),
                entries,
                total,
            });
        }
    }
}

impl Drop for ScanProgressReporter {
    fn drop(&mut self) {
        self.phases.take();
        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
    }
}
