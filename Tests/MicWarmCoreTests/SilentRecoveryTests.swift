import Foundation
import MicWarmCore
import XCTest

final class SilentRecoveryTests: XCTestCase {
    let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)

    func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    // Silent buffers on a Bluetooth input from `streakStart` up to `now`.
    func silent(_ ep: inout SilentRecoveryEpisode, streakStart: TimeInterval, now: TimeInterval,
                bluetooth: Bool = true) -> Int? {
        ep.silentBuffer(streakStart: at(streakStart))
        return ep.restartAttempt(isBluetooth: bluetooth, streakStart: at(streakStart), now: at(now))
    }

    func testThresholdsGrowByTwoSeconds() {
        XCTAssertEqual(SilentRecoveryEpisode.threshold(forAttempt: 0), 4.0)
        XCTAssertEqual(SilentRecoveryEpisode.threshold(forAttempt: 1), 6.0)
        XCTAssertEqual(SilentRecoveryEpisode.threshold(forAttempt: 2), 8.0)
    }

    func testFirstRestartWaitsForFourSeconds() {
        var ep = SilentRecoveryEpisode()
        XCTAssertNil(silent(&ep, streakStart: 0, now: 3.9))
        XCTAssertEqual(silent(&ep, streakStart: 0, now: 4.0), 1)
        XCTAssertTrue(ep.restartPending)
    }

    func testNoSecondRestartWhileOneIsPending() {
        var ep = SilentRecoveryEpisode()
        XCTAssertEqual(silent(&ep, streakStart: 0, now: 4), 1)
        XCTAssertNil(silent(&ep, streakStart: 0, now: 20))
        XCTAssertEqual(ep.attempts, 1)
    }

    func testLaterAttemptsUseLongerThresholdsFromEachNewStreak() {
        var ep = SilentRecoveryEpisode()
        XCTAssertEqual(silent(&ep, streakStart: 0, now: 4), 1)

        ep.sessionStarted()  // replacement session; its silent streak restarts the clock
        XCTAssertNil(silent(&ep, streakStart: 5, now: 10.9))
        XCTAssertEqual(silent(&ep, streakStart: 5, now: 11), 2)

        ep.sessionStarted()
        XCTAssertNil(silent(&ep, streakStart: 12, now: 19.9))
        XCTAssertEqual(silent(&ep, streakStart: 12, now: 20), 3)
    }

    func testCapsAtThreeAttemptsPerEpisode() {
        var ep = SilentRecoveryEpisode()
        var streak: TimeInterval = 0
        for expected in 1...3 {
            ep.sessionStarted()
            let wait = SilentRecoveryEpisode.threshold(forAttempt: expected - 1)
            XCTAssertEqual(silent(&ep, streakStart: streak, now: streak + wait), expected)
            streak += wait + 1
        }
        ep.sessionStarted()
        XCTAssertNil(silent(&ep, streakStart: streak, now: streak + 1000))
        XCTAssertEqual(ep.attempts, SilentRecoveryEpisode.maxAttempts)
    }

    func testBuiltInMicNeverRestarts() {
        var ep = SilentRecoveryEpisode()
        XCTAssertNil(silent(&ep, streakStart: 0, now: 60, bluetooth: false))
        XCTAssertEqual(ep.attempts, 0)
        // The episode is still tracked for the metric line.
        XCTAssertEqual(ep.start, at(0))
    }

    func testEpisodeSpansRestartsAndReportsTotalGap() {
        var ep = SilentRecoveryEpisode()
        XCTAssertEqual(silent(&ep, streakStart: 0, now: 4), 1)
        ep.sessionStarted()
        _ = silent(&ep, streakStart: 5, now: 6)
        XCTAssertEqual(ep.start, at(0), "a new session's streak must not move the episode start")

        let summary = ep.audioRestored(now: at(9.5))
        XCTAssertEqual(summary?.total, 9.5)
        XCTAssertEqual(summary?.restarts, 1)
    }

    func testRestoredAudioResetsTheEpisode() {
        var ep = SilentRecoveryEpisode()
        XCTAssertEqual(silent(&ep, streakStart: 0, now: 4), 1)
        _ = ep.audioRestored(now: at(5))
        XCTAssertNil(ep.start)
        XCTAssertEqual(ep.attempts, 0)

        // A fresh episode gets the full attempt budget and the 4s first threshold again.
        ep.sessionStarted()
        XCTAssertNil(silent(&ep, streakStart: 100, now: 103))
        XCTAssertEqual(silent(&ep, streakStart: 100, now: 104), 1)
    }

    func testShortBlipWithoutRestartIsNotReported() {
        var ep = SilentRecoveryEpisode()
        _ = silent(&ep, streakStart: 0, now: 1)
        XCTAssertNil(ep.audioRestored(now: at(2.0)))
        XCTAssertNil(ep.start)
    }

    func testGapOverTwoSecondsIsReportedWithZeroRestarts() {
        var ep = SilentRecoveryEpisode()
        _ = silent(&ep, streakStart: 0, now: 3)
        let summary = ep.audioRestored(now: at(3.5))
        XCTAssertEqual(summary?.total, 3.5)
        XCTAssertEqual(summary?.restarts, 0)
    }

    func testRestoredWithoutEpisodeReportsNothing() {
        var ep = SilentRecoveryEpisode()
        XCTAssertNil(ep.audioRestored(now: at(10)))
    }
}
