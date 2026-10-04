import Foundation

/// Tracks recent metronome click times on a shared monotonic sample clock so that pitch
/// analysis can reject microphone frames that arrive while the app's own click transient is
/// still audible.
///
/// All timestamps are in seconds on the same clock used by the metronome (e.g.
/// `AVAudioTime.hostTime`-derived sample time) — never mix clocks, or rejection will drift.
public struct ClickRejection {
    /// Rejection window after a click, in seconds (PLAN allows 10-30 ms).
    public let windowSeconds: Double

    /// Click times (seconds) still potentially inside the window.
    private var recentClicks: [Double] = []

    public init(windowSeconds: Double = 0.025) {
        self.windowSeconds = windowSeconds
    }

    /// Record that a click was produced at `sampleTime` seconds on the shared clock.
    public mutating func registerClick(atSampleTime sampleTime: Double) {
        // Drop anything already stale so the array stays tiny under continuous clicking.
        recentClicks.removeAll { sampleTime - $0 > windowSeconds }
        recentClicks.append(sampleTime)
    }

    /// True when `sampleTime` falls within `windowSeconds` after any registered click.
    public func shouldReject(atSampleTime sampleTime: Double) -> Bool {
        for click in recentClicks {
            let delta = sampleTime - click
            if delta >= 0 && delta <= windowSeconds {
                return true
            }
        }
        return false
    }

    /// Remove click entries that can no longer reject a frame at `nowSampleTime`.
    public mutating func prune(nowSampleTime: Double) {
        recentClicks.removeAll { nowSampleTime - $0 > windowSeconds }
    }
}
