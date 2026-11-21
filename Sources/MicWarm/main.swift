import AppKit
import AVFoundation
import CoreAudio
import Darwin
import Foundation
import MicWarmCore
import MicWarmEngine

// The mic-warm command-line daemon. The capture engine lives in MicWarmEngine, shared with
// the Mic Warm app; this file adds the instance lock, signals, and launchd log rotation.

// MARK: - Single instance

// One mic-warm per user. A new instance replaces a running one, but only signals a process
// that holds the lock and whose executable is mic-warm (see InstanceLock). The old
// /tmp/mic-warm.pid scheme trusted any PID in a world-writable file and could SIGTERM an
// unrelated process after PID reuse.
let instanceLockPath = ProcessInfo.processInfo.environment["MIC_WARM_LOCK"]
    ?? (NSHomeDirectory() as NSString).appendingPathComponent("Library/Application Support/mic-warm/mic-warm.lock")
let instanceLock = InstanceLock(path: instanceLockPath)

func acquireInstanceLock() {
    let deadline = Date().addingTimeInterval(5)
    var signalled = false
    while true {
        switch instanceLock.tryAcquire() {
        case .acquired:
            return
        case .failed(let err):
            log("Warning: instance lock \(instanceLockPath) unavailable (\(err)); continuing without it")
            return
        case .held(let owner):
            if !signalled {
                signalled = true
                if let owner, InstanceLock.isMicWarmProcess(owner) {
                    log("Replacing running instance (PID: \(owner))")
                    kill(owner, SIGTERM)
                } else {
                    log("Instance lock is held by \(owner.map { "PID \($0)" } ?? "an unknown process"), which is not mic-warm; waiting for it")
                }
            }
            if Date() >= deadline {
                log("Error: another process still holds \(instanceLockPath); exiting")
                exit(1)
            }
            usleep(100_000)
        }
    }
}

// MARK: - Signal handling & main

let keeper = MicKeeper()

func installSignalHandlers() {
    let handler: @convention(c) (Int32) -> Void = { sig in
        signal(SIGTERM, SIG_DFL)
        signal(SIGINT, SIG_DFL)
        keeper.signalShutdown()
        _exit(0)
    }
    signal(SIGTERM, handler)
    signal(SIGINT, handler)
}

installSignalHandlers()

// Manual diagnostic trigger: `kill -USR1 <pid>` forces a BT/coreaudio capture on demand,
// without waiting for a flat episode. Lets us verify the capture path works and re-test it
// later. Uses a DispatchSource (not a raw signal handler) so it can safely do real work;
// SIG_IGN first so SIGUSR1's default (terminate) doesn't kill the process before GCD delivers it.
signal(SIGUSR1, SIG_IGN)
let sigusr1Source = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .global(qos: .utility))
sigusr1Source.setEventHandler {
    log("[bt-capture] Manual capture trigger (SIGUSR1)")
    logAllDevices(prefix: "[manual-diag]")
    captureSystemAudioBTLog(reason: "manual SIGUSR1 trigger", seconds: 30)
}
sigusr1Source.resume()

// Cap the main log. launchd opens StandardOutPath once and hands us the fds, so the
// process rotates the file itself: rename to mic-warm.log.1 and point stdout/stderr at a
// fresh file. A run from a terminal (stdout not that file) is left alone, as is a plist that
// still points at the old /tmp path (re-run install.sh to move it). Checked every 60s, so
// the cap is soft by up to a minute of output.
let mainLogPath = (btLogDir as NSString).appendingPathComponent("mic-warm.log")
let logRotationTimer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
logRotationTimer.schedule(deadline: .now() + 60, repeating: 60, leeway: .seconds(10))
logRotationTimer.setEventHandler {
    switch LogRotation.rotateInheritedLog(mainLogPath) {
    case .rotated: log("[log] Rotated previous log to \(mainLogPath).1 (cap \(LogRotation.maxBytes / 1024 / 1024)MB)")
    case .failed(let err): log("[log] WARNING: log rotation failed: \(err)")
    case .notNeeded: break
    }
}
logRotationTimer.resume()

log("mic-warm starting (PID: \(ProcessInfo.processInfo.processIdentifier), version: 0.11.2)")
log("[silent-recovery] Enabled: restart Bluetooth session after \((0..<SilentRecoveryEpisode.maxAttempts).map { "\(Int(SilentRecoveryEpisode.threshold(forAttempt: $0)))s" }.joined(separator: "/")) of silent buffers (max \(SilentRecoveryEpisode.maxAttempts) attempts/episode)")
log("[bt-capture] Flat-signal Bluetooth/coreaudio diagnostics enabled -> \(btLogPath)")
log("[bt-capture] Manual trigger: kill -USR1 \(ProcessInfo.processInfo.processIdentifier)")
acquireInstanceLock()
keeper.start()
// NSApplication.shared.run() services both the GCD main queue (like dispatchMain())
// AND the NSApplication run loop, which is required for NSWorkspace sleep/wake
// notifications. Safe for headless LaunchAgent use.
NSApplication.shared.run()
