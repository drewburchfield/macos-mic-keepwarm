import Darwin
import Foundation
import MicWarmCore

// MARK: - Bluetooth/coreaudio unified-log capture

// The macOS unified log holds the SCO/HFP/codec transitions that CoreAudio property values
// can't show, but on a busy system it rotates within tens of minutes. So we snapshot it into a
// dedicated file the moment a flat signal is detected (and again on recovery), before it ages out.
//
// Written under a user-owned 0700 dir in ~/Library/Logs (not /tmp): a world-writable directory
// with a predictable filename is a symlink/TOCTOU target (an attacker could pre-plant a symlink
// and redirect the truncating createFile to clobber a user-writable file). ~/Library/Logs is also
// the idiomatic macOS log location and survives reboots, unlike /tmp.
public let btLogDir = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Logs/mic-warm")
public let btLogPath = (btLogDir as NSString).appendingPathComponent("bt.log")
let btLogQueue = DispatchQueue(label: "com.micwarm.btlog", qos: .utility)

public func captureSystemAudioBTLog(reason: String, seconds: Int) {
    btLogQueue.async {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        proc.arguments = [
            "show", "--last", "\(seconds)s", "--info", "--debug", "--style", "compact",
            "--predicate",
            "(process == \"bluetoothd\") OR (process == \"coreaudiod\") OR (subsystem BEGINSWITH \"com.apple.bluetooth\") OR (subsystem == \"com.apple.coreaudio\")"
        ]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        do {
            try proc.run()
        } catch {
            log("[bt-capture] Failed to launch log show: \(error.localizedDescription)")
            return
        }

        // Read on a separate queue so the whole capture can be bounded by a timeout. `log show`
        // is normally <2s but was observed taking 75s+ once; without a bound, a slow run would
        // wedge this serial queue and a later (e.g. recovery) capture would never run. The
        // semaphore also establishes happens-before ordering for the read of `data` below.
        var data = Data()
        let reader = DispatchQueue(label: "com.micwarm.btlog.read")
        let done = DispatchSemaphore(value: 0)
        reader.async {
            data = pipe.fileHandleForReading.readDataToEndOfFile()
            done.signal()
        }
        let timedOut = done.wait(timeout: .now() + 30) == .timedOut
        if timedOut {
            log("[bt-capture] log show exceeded 30s; terminating, writing partial :: \(reason)")
            proc.terminate()  // closes the pipe write end -> the read above hits EOF and returns
            if done.wait(timeout: .now() + 5) == .timedOut {
                // SIGTERM ignored: force it, and give up on the reader rather than wedge this queue.
                kill(proc.processIdentifier, SIGKILL)
                if done.wait(timeout: .now() + 5) == .timedOut {
                    log("[bt-capture] log show did not exit after SIGKILL; skipping capture :: \(reason)")
                    return
                }
            }
        }
        // EOF on the pipe normally means log show has exited; bound the wait anyway.
        let exitDeadline = Date().addingTimeInterval(5)
        while proc.isRunning && Date() < exitDeadline { usleep(50_000) }
        if proc.isRunning {
            kill(proc.processIdentifier, SIGKILL)
            usleep(200_000)
        }
        // terminationStatus raises if the process is still running.
        let status = proc.isRunning ? -1 : proc.terminationStatus
        if !timedOut && status != 0 {
            log("[bt-capture] log show failed (status \(status)); its output is saved below :: \(reason)")
        }

        let header = "\n========== [\(logDateFormatter.string(from: Date()))] BT/coreaudio capture (last \(seconds)s\(timedOut ? ", TIMED OUT - partial" : ""), exit=\(status)) :: \(reason) ==========\n"
        let fm = FileManager.default
        do {
            // 0700 dir owned by us means no other user can plant a symlink to redirect our writes.
            try fm.createDirectory(atPath: btLogDir, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            // Each capture is ~1.5-2MB; bt.log plus bt.log.1 keep roughly the last 5-10.
            // An unusually large capture keeps only its newest bytes, so no file passes the cap.
            let headerData = Data(header.utf8)
            let room = Int(LogRotation.maxBytes) - headerData.count
            let body = data.count > room ? data.suffix(room) : data
            if body.count < data.count {
                log("[bt-capture] Capture of \(data.count) bytes exceeds the cap; keeping the last \(body.count)")
            }
            switch LogRotation.rotateIfNeeded(btLogPath, incoming: off_t(headerData.count + body.count)) {
            case .rotated: log("[bt-capture] Rotated \(btLogPath) to bt.log.1")
            case .failed(let err): log("[bt-capture] WARNING: rotating \(btLogPath) failed: \(err)")
            case .notNeeded: break
            }
            if !fm.fileExists(atPath: btLogPath),
               !fm.createFile(atPath: btLogPath, contents: nil, attributes: [.posixPermissions: 0o600]) {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: btLogPath])
            }
            // The throwing FileHandle APIs: the legacy write(_:) raises an uncatchable
            // Objective-C exception on ENOSPC, which would crash the daemon.
            let fh = try FileHandle(forWritingTo: URL(fileURLWithPath: btLogPath))
            defer { try? fh.close() }
            try fh.seekToEnd()
            try fh.write(contentsOf: headerData)
            try fh.write(contentsOf: body)
            log("[bt-capture] Wrote \(body.count) bytes to \(btLogPath)\(timedOut ? " (partial)" : "") :: \(reason)")
        } catch {
            log("[bt-capture] FAILED to write \(btLogPath): \(error.localizedDescription) :: \(reason)")
        }
    }
}

