//! Burst buffering + starvation guard.
//! The swarm may fill a window ahead of the playhead at full speed; once the window is full the download drops to a
//! modest idle rate (IDLE_DOWNLOAD_BPS, never below one 16 KiB chunk per second, or librqbit disconnects the peers)
//! until playback drains it to the low mark. A read that waits for data lifts the limit at once and blocks
//! re-throttling for a cooldown, so throttling can never stall playback.
use std::{
    collections::HashMap,
    num::NonZeroU32,
    sync::{
        atomic::{AtomicBool, AtomicU64, Ordering::Relaxed},
        Arc, Mutex,
    },
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use librqbit::Session;
use tokio::sync::Notify;

use crate::{
    engine::Shared,
    pacer_logic::{decide, is_jump, is_stalled, window, Estimator, COOLDOWN_MS, IDLE_DOWNLOAD_BPS, STALL_GRACE_MS},
};

#[derive(Default)]
pub struct Pace {
    /// End offset of the last byte handed to the player (file-relative).
    served: AtomicU64,
    /// Bumped on every real seek (not on contiguous range continuations).
    epoch: AtomicU64,
    /// Low Power Mode / thermal pressure: smaller window.
    pub low_power: AtomicBool,
    /// Set by the pacer while the download limit is on; only then do waiting reads wake it.
    throttled: AtomicBool,
    next_id: AtomicU64,
    /// In-flight reads that are waiting for data: id -> unix ms when the wait began.
    waiters: Mutex<HashMap<u64, u64>>,
    stalled: Notify,
}

pub fn now_ms() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis() as u64).unwrap_or(0)
}

impl Pace {
    /// New stream: forget everything.
    pub fn reset(&self) {
        self.served.store(0, Relaxed);
        self.epoch.fetch_add(1, Relaxed);
        self.throttled.store(false, Relaxed);
        self.waiters.lock().unwrap_or_else(|e| e.into_inner()).clear();
    }

    /// Called when an HTTP request begins reading at `start`. A real seek bumps the epoch and moves the playhead.
    pub fn note_request(&self, start: u64) {
        if is_jump(self.served.load(Relaxed), start) {
            self.served.store(start, Relaxed);
            self.epoch.fetch_add(1, Relaxed);
        }
    }

    pub fn advance(&self, end: u64) {
        self.served.store(end, Relaxed);
    }

    /// Age in ms of the oldest read that is waiting for data.
    fn oldest_wait_age(&self, now: u64) -> Option<u64> {
        let g = self.waiters.lock().unwrap_or_else(|e| e.into_inner());
        g.values().min().map(|&s| now.saturating_sub(s))
    }
}

/// Registers a waiting read for as long as it lives; removed on completion AND on cancellation (client disconnect).
pub struct WaitGuard {
    pace: Arc<Pace>,
    id: u64,
}
impl WaitGuard {
    pub fn new(p: &Arc<Pace>) -> Self {
        let id = p.next_id.fetch_add(1, Relaxed);
        p.waiters.lock().unwrap_or_else(|e| e.into_inner()).insert(id, now_ms());
        if p.throttled.load(Relaxed) {
            p.stalled.notify_one(); // wake the pacer now instead of at its next tick
        }
        Self { pace: p.clone(), id }
    }
}
impl Drop for WaitGuard {
    fn drop(&mut self) {
        self.pace.waiters.lock().unwrap_or_else(|e| e.into_inner()).remove(&self.id);
    }
}

pub async fn run(session: Arc<Session>, shared: Arc<Shared>, id: usize) {
    let idle = NonZeroU32::new(IDLE_DOWNLOAD_BPS);
    let mut throttled = false;
    let mut est = Estimator::default();
    let mut cooldown_until = 0u64;
    loop {
        let woken = tokio::select! {
            _ = tokio::time::sleep(Duration::from_secs(2)) => false,
            _ = shared.pace.stalled.notified() => true,
        };
        if woken {
            // brief grace so a read that only needed a few ms is not treated as a stall
            tokio::time::sleep(Duration::from_millis(STALL_GRACE_MS)).await;
        }
        let handle = match shared.current.read() {
            Ok(g) => match g.as_ref() {
                Some(c) if c.id == id => c.handle.clone(),
                _ => break, // stream replaced or stopped
            },
            Err(_) => break,
        };
        let pace = &shared.pace;
        let now = now_ms();
        if is_stalled(pace.oldest_wait_age(now), throttled) {
            cooldown_until = now + COOLDOWN_MS;
        }
        let (high, low) = window(pace.low_power.load(Relaxed));
        let ahead = est.ahead(pace.epoch.load(Relaxed), handle.stats().progress_bytes, pace.served.load(Relaxed));
        let want = decide(throttled, ahead, high, low, now < cooldown_until);
        if want != throttled {
            session.ratelimits.set_download_bps(if want { idle } else { None });
            throttled = want;
            pace.throttled.store(want, Relaxed);
        }
    }
    session.ratelimits.set_download_bps(None);
    shared.pace.throttled.store(false, Relaxed);
}
