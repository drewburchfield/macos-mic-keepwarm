import Foundation

/// Silent-recovery episode tracking: when to restart a Bluetooth session that delivers
/// all-zero buffers, and how long the user-visible gap lasted.
///
/// A flat episode is one continuous run of silent buffers from the user's perspective,
/// possibly spanning several sessions as recovery restarts tear them down. The episode
/// survives `sessionStarted()` and clears only when a non-silent buffer arrives.
///
/// Mechanism (confirmed 2026-08-31): during an AirPods multipoint handoff, CoreAudio
/// brings the input device up and delivers zero-filled buffers while bluetoothd has not
/// yet established the SCO voice link. A fresh AVCaptureSession issues a new audio
/// routing request to audiomxd, the same kind of request observed to trigger SCO
/// renegotiation, so restarting the session can end the gap instead of waiting it out.
///
/// Not thread-safe; the owner confines it to one queue.
public struct SilentRecoveryEpisode {
    public static let maxAttempts = 3

    /// Give bluetoothd progressively longer to finish SCO setup before poking it again.
    public static func threshold(forAttempt attempt: Int) -> TimeInterval {
        return 4.0 + Double(attempt) * 2.0  // 4s, 6s, 8s
    }

    /// Start of the current flat episode, or nil when audio is flowing.
    public private(set) var start: Date?
    /// Restarts issued during the current episode.
    public private(set) var attempts = 0
    /// A restart was requested and the replacement session has not started yet.
    public private(set) var restartPending = false

    public init() {}

    /// Record a silent buffer. `streakStart` is when the current session's silent streak began.
    public mutating func silentBuffer(streakStart: Date) {
        if start == nil { start = streakStart }
    }

    /// Whether to restart now. Returns the attempt number (1-based) to log, or nil.
    /// Bluetooth only: all-zero buffers on the built-in mic mean something else
    /// (e.g. input mute), where a restart would just churn.
    public mutating func restartAttempt(isBluetooth: Bool, streakStart: Date, now: Date) -> Int? {
        guard isBluetooth, !restartPending, attempts < Self.maxAttempts else { return nil }
        guard now.timeIntervalSince(streakStart) >= Self.threshold(forAttempt: attempts) else { return nil }
        attempts += 1
        restartPending = true
        return attempts
    }

    /// Call when a session (re)start begins. Clears the pending flag, so the next silent
    /// streak may trigger another attempt.
    public mutating func sessionStarted() {
        restartPending = false
    }

    /// Record a non-silent buffer, ending any episode. Returns the episode summary to log
    /// (total user-perceived gap across restarts, and the restart count) when the gap was
    /// long enough to matter or a restart was involved.
    public mutating func audioRestored(now: Date) -> (total: TimeInterval, restarts: Int)? {
        defer {
            start = nil
            attempts = 0
        }
        guard let start else { return nil }
        let total = now.timeIntervalSince(start)
        guard total > 2.0 || attempts > 0 else { return nil }
        return (total, attempts)
    }
}
