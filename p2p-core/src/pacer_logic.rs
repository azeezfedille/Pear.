//! Pure pacing decisions (no librqbit, no clocks, no atomics) so they can be unit-tested on their own.

pub const MIB: u64 = 1 << 20;

/// librqbit's rate limiter (governor) has a burst equal to the rate. A request bigger than the burst
/// (peers ask for 16 KiB chunks) fails immediately and librqbit then drops the peer. So no limit, download or
/// upload, may ever be set below one chunk per second. 16 KiB/s is the floor.
pub const MIN_LIMIT_BPS: u32 = 16 * 1024;
/// Download rate while the read-ahead window is full. Well above the floor, so peers stay connected and trickle.
pub const IDLE_DOWNLOAD_BPS: u32 = 128 * 1024;

/// A new HTTP Range request starting within this distance of the last served byte continues the same read
/// (AetherEngine opens a new contiguous range every 8-16 MB); anything further away is a real seek.
pub const CONTINUATION_SLACK: u64 = 2 * MIB;
/// A read waiting this long while the limit is on means the buffer estimate was wrong: lift the limit.
pub const STALL_GRACE_MS: u64 = 250;
/// A read waiting this long while unthrottled also counts as a stall.
pub const STARVE_MS: u64 = 1500;
/// After a stall, do not throttle again for this long.
pub const COOLDOWN_MS: u64 = 20_000;

pub fn clamp_limit(bps: u32) -> u32 {
    bps.max(MIN_LIMIT_BPS)
}

/// (high, low) watermarks in bytes. Throttle above `high`, release below `low`.
pub fn window(low_power: bool) -> (u64, u64) {
    if low_power { (16 * MIB, 6 * MIB) } else { (48 * MIB, 16 * MIB) }
}

/// True when a request starting at `start` is NOT a continuation of the stream that last served up to `served`.
pub fn is_jump(served: u64, start: u64) -> bool {
    start.saturating_add(CONTINUATION_SLACK) < served || start > served.saturating_add(CONTINUATION_SLACK)
}

/// Estimates how many bytes are buffered ahead of the playhead.
/// Counts bytes downloaded since the last real jump minus bytes consumed since then, so it resets on a seek
/// and not on a continuation request.
#[derive(Default)]
pub struct Estimator {
    epoch: Option<u64>,
    anchor_progress: u64,
    anchor_served: u64,
}

impl Estimator {
    pub fn ahead(&mut self, epoch: u64, progress: u64, served: u64) -> u64 {
        if self.epoch != Some(epoch) {
            self.epoch = Some(epoch);
            self.anchor_progress = progress;
            self.anchor_served = served;
        }
        let downloaded = progress.saturating_sub(self.anchor_progress);
        let consumed = served.saturating_sub(self.anchor_served);
        downloaded.saturating_sub(consumed)
    }
}

/// Should the download be throttled now? `hold_open` = a stall happened recently, never throttle.
pub fn decide(throttled: bool, ahead: u64, high: u64, low: u64, hold_open: bool) -> bool {
    if hold_open || ahead < low {
        false
    } else if ahead > high {
        true
    } else {
        throttled // hysteresis between the watermarks
    }
}

/// Is a read starved? `age_ms` is the age of the oldest waiting read.
pub fn is_stalled(age_ms: Option<u64>, throttled: bool) -> bool {
    let limit = if throttled { STALL_GRACE_MS } else { STARVE_MS };
    age_ms.map_or(false, |a| a > limit)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn limits_never_below_one_chunk() {
        assert_eq!(clamp_limit(1024), MIN_LIMIT_BPS);
        assert_eq!(clamp_limit(0), MIN_LIMIT_BPS);
        assert_eq!(clamp_limit(64 * 1024), 64 * 1024);
        assert!(IDLE_DOWNLOAD_BPS >= MIN_LIMIT_BPS);
    }

    #[test]
    fn contiguous_range_is_not_a_jump() {
        assert!(!is_jump(100 * MIB, 100 * MIB));
        assert!(!is_jump(100 * MIB, 100 * MIB - MIB)); // small re-read
        assert!(!is_jump(0, 0));
    }

    #[test]
    fn real_seeks_are_jumps() {
        assert!(is_jump(100 * MIB, 10 * MIB)); // back
        assert!(is_jump(100 * MIB, 900 * MIB)); // forward
        assert!(is_jump(0, 500 * MIB)); // resume at an offset
    }

    #[test]
    fn estimator_tracks_download_minus_consumption() {
        let mut e = Estimator::default();
        assert_eq!(e.ahead(0, 0, 0), 0);
        assert_eq!(e.ahead(0, 60 * MIB, 5 * MIB), 55 * MIB);
        assert_eq!(e.ahead(0, 60 * MIB, 40 * MIB), 20 * MIB);
    }

    #[test]
    fn estimator_resets_only_on_epoch_change() {
        let mut e = Estimator::default();
        e.ahead(0, 0, 0);
        assert_eq!(e.ahead(0, 80 * MIB, 10 * MIB), 70 * MIB);
        // seek back: the old estimate must not leak into the new position
        assert_eq!(e.ahead(1, 80 * MIB, 2 * MIB), 0);
        assert_eq!(e.ahead(1, 90 * MIB, 3 * MIB), 9 * MIB);
    }

    #[test]
    fn estimator_never_underflows() {
        let mut e = Estimator::default();
        e.ahead(0, 50 * MIB, 50 * MIB);
        assert_eq!(e.ahead(0, 10 * MIB, 90 * MIB), 0);
    }

    #[test]
    fn decide_has_hysteresis() {
        let (high, low) = window(false);
        assert!(decide(false, high + 1, high, low, false));
        assert!(decide(true, (high + low) / 2, high, low, false)); // stays throttled between marks
        assert!(!decide(false, (high + low) / 2, high, low, false)); // stays open between marks
        assert!(!decide(true, low - 1, high, low, false));
    }

    #[test]
    fn cooldown_blocks_throttling() {
        let (high, low) = window(false);
        assert!(!decide(false, high * 2, high, low, true));
    }

    #[test]
    fn stall_thresholds() {
        assert!(!is_stalled(None, true));
        assert!(is_stalled(Some(STALL_GRACE_MS + 1), true));
        assert!(!is_stalled(Some(STALL_GRACE_MS + 1), false));
        assert!(is_stalled(Some(STARVE_MS + 1), false));
    }

    #[test]
    fn low_power_window_is_smaller() {
        assert!(window(true).0 < window(false).0);
        assert!(window(true).1 < window(true).0);
    }
}
