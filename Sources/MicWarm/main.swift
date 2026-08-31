import AppKit
import AVFoundation
import CoreAudio
import Darwin
import Foundation

// MARK: - Logging

// ISO8601DateFormatter is thread-safe, unlike DateFormatter.
// log() is called from multiple queues.
let logDateFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withTime, .withColonSeparatorInTime, .withFractionalSeconds]
    f.timeZone = .current
    return f
}()

func log(_ msg: String) {
    print("[\(logDateFormatter.string(from: Date()))] \(msg)")
    fflush(stdout)
}

// MARK: - CoreAudio Helpers

func getAudioProperty<T>(_ objectID: AudioObjectID, selector: AudioObjectPropertySelector,
                          scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> T? {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                              mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(MemoryLayout<T>.size)
    var value = UnsafeMutablePointer<T>.allocate(capacity: 1)
    defer { value.deallocate() }
    let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, value)
    guard status == noErr else { return nil }
    return value.pointee
}

func allowSystemIdleSleep() {
    let systemObject = AudioObjectID(kAudioObjectSystemObject)
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertySleepingIsAllowed,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var allowSleep: UInt32 = 1

    let status = AudioObjectSetPropertyData(
        systemObject,
        &address,
        0,
        nil,
        UInt32(MemoryLayout<UInt32>.size),
        &allowSleep)

    guard status == noErr else {
        log("[power] Could not allow system idle sleep (OSStatus: \(status))")
        return
    }

    let configuredValue: UInt32? = getAudioProperty(
        systemObject,
        selector: kAudioHardwarePropertySleepingIsAllowed)
    guard configuredValue == 1 else {
        log("[power] Could not verify that system idle sleep is allowed")
        return
    }

    log("[power] System idle sleep allowed during microphone capture")
}

func getStringProperty(_ objectID: AudioObjectID, selector: AudioObjectPropertySelector) -> String? {
    var address = AudioObjectPropertyAddress(mSelector: selector,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
    var name: CFString = "" as CFString
    var size = UInt32(MemoryLayout<CFString>.size)
    let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &name)
    guard status == noErr else { return nil }
    return name as String
}

func getAllAudioDeviceIDs() -> [AudioDeviceID] {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size)
    let count = Int(size) / MemoryLayout<AudioDeviceID>.size
    var devices = [AudioDeviceID](repeating: 0, count: count)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices)
    return devices
}

func transportTypeName(_ type: UInt32) -> String {
    switch type {
    case kAudioDeviceTransportTypeBuiltIn: return "built-in"
    case kAudioDeviceTransportTypeBluetooth: return "bluetooth"
    case kAudioDeviceTransportTypeBluetoothLE: return "bluetooth-le"
    case kAudioDeviceTransportTypeUSB: return "usb"
    case kAudioDeviceTransportTypeFireWire: return "firewire"
    case kAudioDeviceTransportTypeVirtual: return "virtual"
    case kAudioDeviceTransportTypeAggregate: return "aggregate"
    case kAudioDeviceTransportTypeUnknown: return "unknown"
    default:
        let chars = [
            Character(UnicodeScalar((type >> 24) & 0xFF)!),
            Character(UnicodeScalar((type >> 16) & 0xFF)!),
            Character(UnicodeScalar((type >> 8) & 0xFF)!),
            Character(UnicodeScalar(type & 0xFF)!)
        ]
        return "0x\(String(format: "%08X", type)) (\(String(chars)))"
    }
}

func describeDevice(_ deviceID: AudioDeviceID) -> String {
    let name = getStringProperty(deviceID, selector: kAudioObjectPropertyName) ?? "?"
    let uid = getStringProperty(deviceID, selector: kAudioDevicePropertyDeviceUID) ?? "?"
    let transport: UInt32 = getAudioProperty(deviceID, selector: kAudioDevicePropertyTransportType) ?? 0
    let isAlive: UInt32 = getAudioProperty(deviceID, selector: kAudioDevicePropertyDeviceIsAlive) ?? 0
    let isRunning: UInt32 = getAudioProperty(deviceID, selector: kAudioDevicePropertyDeviceIsRunning) ?? 0
    let isRunningSomewhere: UInt32 = getAudioProperty(deviceID, selector: kAudioDevicePropertyDeviceIsRunningSomewhere) ?? 0
    let hogPID: pid_t = getAudioProperty(deviceID, selector: kAudioDevicePropertyHogMode) ?? -1

    var inputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreams,
        mScope: kAudioObjectPropertyScopeInput,
        mElement: kAudioObjectPropertyElementMain)
    var inputSize: UInt32 = 0
    AudioObjectGetPropertyDataSize(deviceID, &inputAddress, 0, nil, &inputSize)
    let inputStreams = Int(inputSize) / MemoryLayout<AudioStreamID>.size

    return "\(name) [id=\(deviceID) uid=\(uid) transport=\(transportTypeName(transport)) alive=\(isAlive) running=\(isRunning) runningSomewhere=\(isRunningSomewhere) hogPID=\(hogPID) inputStreams=\(inputStreams)]"
}

// The first input stream's active (virtual) format. The clearest in-process signal for the
// Bluetooth profile in use: HFP/SCO presents as ~8k/16kHz mono, whereas other modes differ.
// Comparing this at flat-onset vs recovery tells us whether the SCO link was actually carrying audio.
func inputStreamFormatDescription(_ deviceID: AudioDeviceID) -> String {
    guard deviceID > 0 else { return "no device" }
    var streamsAddr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreams,
        mScope: kAudioObjectPropertyScopeInput,
        mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    AudioObjectGetPropertyDataSize(deviceID, &streamsAddr, 0, nil, &size)
    let count = Int(size) / MemoryLayout<AudioStreamID>.size
    guard count > 0 else { return "no input streams" }
    var streams = [AudioStreamID](repeating: 0, count: count)
    AudioObjectGetPropertyData(deviceID, &streamsAddr, 0, nil, &size, &streams)

    var fmtAddr = AudioObjectPropertyAddress(
        mSelector: kAudioStreamPropertyVirtualFormat,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var asbd = AudioStreamBasicDescription()
    var asbdSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    let status = AudioObjectGetPropertyData(streams[0], &fmtAddr, 0, nil, &asbdSize, &asbd)
    guard status == noErr else { return "format query failed (status \(status), streams=\(count))" }

    let fid = asbd.mFormatID
    let fourcc = "\(Character(UnicodeScalar((fid >> 24) & 0xFF) ?? " "))"
        + "\(Character(UnicodeScalar((fid >> 16) & 0xFF) ?? " "))"
        + "\(Character(UnicodeScalar((fid >> 8) & 0xFF) ?? " "))"
        + "\(Character(UnicodeScalar(fid & 0xFF) ?? " "))"
    return "sampleRate=\(asbd.mSampleRate) ch=\(asbd.mChannelsPerFrame) bits=\(asbd.mBitsPerChannel) format='\(fourcc)' streams=\(count)"
}

func logAllDevices(prefix: String) {
    let devices = getAllAudioDeviceIDs()
    log("\(prefix) --- All audio devices (\(devices.count)) ---")
    for d in devices {
        log("\(prefix)   \(describeDevice(d))")
    }

    let defaultInput: AudioDeviceID? = getAudioProperty(
        AudioObjectID(kAudioObjectSystemObject),
        selector: kAudioHardwarePropertyDefaultInputDevice)
    if let di = defaultInput {
        log("\(prefix)   Default input: \(getStringProperty(di, selector: kAudioObjectPropertyName) ?? "?") [id=\(di)]")
    } else {
        log("\(prefix)   Default input: NONE")
    }
}

// MARK: - Bluetooth/coreaudio unified-log capture

// The macOS unified log holds the SCO/HFP/codec transitions that CoreAudio property values
// can't show, but on this machine it rotates in tens of minutes. So we snapshot it into a
// dedicated file the moment a flat signal is detected (and again on recovery), before it ages out.
//
// Written under a user-owned 0700 dir in ~/Library/Logs (not /tmp): a world-writable directory
// with a predictable filename is a symlink/TOCTOU target (an attacker could pre-plant a symlink
// and redirect the truncating createFile to clobber a user-writable file). ~/Library/Logs is also
// the idiomatic macOS log location and survives reboots, unlike /tmp.
let btLogDir = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Logs/mic-warm")
let btLogPath = (btLogDir as NSString).appendingPathComponent("bt.log")
let btLogQueue = DispatchQueue(label: "com.micwarm.btlog", qos: .utility)

func captureSystemAudioBTLog(reason: String, seconds: Int) {
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
            done.wait()
        }
        proc.waitUntilExit()

        let header = "\n========== [\(logDateFormatter.string(from: Date()))] BT/coreaudio capture (last \(seconds)s\(timedOut ? ", TIMED OUT - partial" : "")) :: \(reason) ==========\n"
        let fm = FileManager.default
        // 0700 dir owned by us means no other user can plant a symlink to redirect our writes.
        try? fm.createDirectory(atPath: btLogDir, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        if !fm.fileExists(atPath: btLogPath) {
            fm.createFile(atPath: btLogPath, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        if let fh = FileHandle(forWritingAtPath: btLogPath) {
            fh.seekToEndOfFile()
            fh.write(header.data(using: .utf8) ?? Data())
            fh.write(data)
            try? fh.close()
        }
        log("[bt-capture] Wrote \(data.count) bytes to \(btLogPath)\(timedOut ? " (partial)" : "") :: \(reason)")
    }
}

// MARK: - PID file

let pidPath = "/tmp/mic-warm.pid"

func writePID() {
    do {
        try "\(ProcessInfo.processInfo.processIdentifier)".write(
            toFile: pidPath, atomically: true, encoding: .utf8)
    } catch {
        log("Warning: Could not write PID file \(pidPath): \(error.localizedDescription)")
    }
}

func cleanupPID() {
    unlink(pidPath)
}

func killStalePID() {
    guard let contents = try? String(contentsOfFile: pidPath, encoding: .utf8),
          let old = Int32(contents.trimmingCharacters(in: .whitespacesAndNewlines)),
          old != ProcessInfo.processInfo.processIdentifier
    else { return }
    if kill(old, 0) == 0 {
        log("Killing stale process (PID: \(old))")
        kill(old, SIGTERM)
        usleep(500_000)
    }
    cleanupPID()
}

// MARK: - Per-device listener tracking

struct ListenerRegistration {
    let deviceID: AudioObjectID
    var address: AudioObjectPropertyAddress
    let block: AudioObjectPropertyListenerBlock
}

// MARK: - Capture session

class MicKeeper: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {

    // --- Queues ---
    // Session lifecycle: create, teardown, configure, restart. Never use main for these.
    private let sessionQueue = DispatchQueue(label: "com.micwarm.session")
    // Sample buffer delivery and heartbeat. Confines all sample counting state.
    private let sampleQueue = DispatchQueue(label: "com.micwarm.samples", qos: .userInteractive)
    // CoreAudio per-device listener callbacks. Isolated from both main and session queues.
    private let listenerQueue = DispatchQueue(label: "com.micwarm.listeners")

    // --- Session state (confined to sessionQueue) ---
    private var session: AVCaptureSession?
    private var debounceWork: DispatchWorkItem?
    private let debounceSeconds: Double = 3.0
    private var listenersInstalled = false
    private var sessionID: UInt32 = 0
    private var currentDeviceID: AudioDeviceID = 0
    private var sessionStartTime: Date?
    private var consecutiveZeroSampleRestarts: Int = 0
    private var currentDeviceIsBluetooth: Bool = false

    // --- Sample state (confined to sampleQueue) ---
    private var sampleCount: UInt64 = 0
    private var lastSampleTime: Date?
    private var lastHeartbeatSampleCount: UInt64 = 0
    private var heartbeatTimer: DispatchSourceTimer?
    // Silent-sample tracking: detects "signal goes flat" (samples flow but contain silence)
    private var silentSampleCount: UInt64 = 0
    private var lastSilentSampleCount: UInt64 = 0
    private var silentStreakStart: Date?
    // Ensures the heavy flat-onset diagnostic capture fires only once per silent streak.
    private var silentDiagCaptured: Bool = false
    // Silent-recovery state. A "flat episode" is one continuous run of silent buffers from
    // the user's perspective, possibly spanning several sessions as recovery restarts tear
    // them down, so these survive startSession's per-session reset and clear only when a
    // non-silent buffer arrives. Confined to sampleQueue.
    //
    // Mechanism (confirmed 2026-08-31): during an AirPods multipoint handoff, CoreAudio
    // brings the input device up and delivers zero-filled buffers while bluetoothd has not
    // yet established the SCO voice link. A fresh AVCaptureSession issues a new audio
    // routing request to audiomxd, the same kind of request observed to trigger SCO
    // renegotiation, so restarting the session can end the gap instead of waiting it out.
    private var flatEpisodeStart: Date?
    private var silentRecoveryAttempts: Int = 0
    private var silentRestartPending: Bool = false
    private let silentRecoveryMaxAttempts = 3

    // --- Listener tracking (confined to listenerQueue) ---
    private var perDeviceListeners: [ListenerRegistration] = []

    // MARK: - Startup

    func start() {
        killStalePID()
        writePID()

        log("=== STARTUP DEVICE SNAPSHOT ===")
        logAllDevices(prefix: "[startup]")
        log("=== END STARTUP SNAPSHOT ===")

        sessionQueue.async { [self] in
            guard startSession_onSessionQueue() else {
                log("Error: No audio input device found. Waiting for recovery...")
                scheduleRecovery_onSessionQueue()
                return
            }
            installListenersOnce()
        }
    }

    private func installListenersOnce() {
        guard !listenersInstalled else { return }
        listenersInstalled = true
        installDeviceListener()
        installConnectionObservers()
        installPerDeviceListeners()
        log("[listeners] All system listeners installed")
    }

    // MARK: - Session lifecycle (all on sessionQueue)

    // Start (or restart) the capture session on the current default mic.
    // MUST be called on sessionQueue.
    @discardableResult
    private func startSession_onSessionQueue() -> Bool {
        // Cancel any pending debounced restart
        debounceWork?.cancel()
        debounceWork = nil

        // Tear down old session synchronously. Because we are on sessionQueue (not main),
        // CoreAudio's dispatch_sync(main) for property notifications can still complete,
        // avoiding the CAGuard deadlock that plagued the main-thread approach.
        if let old = session {
            let oldSid = sessionID
            let oldSamples = sampleCount
            log("[session-\(oldSid)] Stopping old session (samples received: \(oldSamples))")

            // Detach delegate first to stop sample callbacks immediately.
            for output in old.outputs {
                if let audioOutput = output as? AVCaptureAudioDataOutput {
                    audioOutput.setSampleBufferDelegate(nil, queue: nil)
                }
            }

            // Remove outputs and inputs on sessionQueue (safe: not main thread).
            for output in old.outputs { old.removeOutput(output) }
            for input in old.inputs { old.removeInput(input) }

            // stopRunning() can hang if CoreAudio's HALB_Guard is waiting on a
            // condition variable for a dead Bluetooth device. Run it on a separate
            // thread with a bounded timeout so sessionQueue isn't blocked forever.
            let group = DispatchGroup()
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                old.stopRunning()
                group.leave()
            }
            let result = group.wait(timeout: .now() + 10.0)
            if result == .timedOut {
                log("[session-\(oldSid)] WARNING: stopRunning() did not complete in 10s (likely deadlocked on dead Bluetooth device)")
            } else {
                log("[session-\(oldSid)] Old session stopped")
            }
        }
        session = nil
        stopHeartbeat_onSampleQueue()

        // Reset sample state on sampleQueue. flatEpisodeStart and silentRecoveryAttempts
        // deliberately survive: they track a flat episode across restarts.
        sampleQueue.sync {
            sampleCount = 0
            silentSampleCount = 0
            lastSilentSampleCount = 0
            silentStreakStart = nil
            lastSampleTime = nil
            silentDiagCaptured = false
            silentRestartPending = false
        }

        sessionStartTime = Date()
        sessionID += 1
        let sid = sessionID

        guard let device = AVCaptureDevice.default(for: .audio) else {
            log("[session-\(sid)] No default audio device found")
            return false
        }

        // Get CoreAudio device ID for this AVCaptureDevice
        currentDeviceID = getAllAudioDeviceIDs().first {
            getStringProperty($0, selector: kAudioDevicePropertyDeviceUID) == device.uniqueID
        } ?? 0

        let transport: UInt32 = currentDeviceID > 0
            ? (getAudioProperty(currentDeviceID, selector: kAudioDevicePropertyTransportType) ?? 0)
            : 0
        currentDeviceIsBluetooth = transport == kAudioDeviceTransportTypeBluetooth
            || transport == kAudioDeviceTransportTypeBluetoothLE

        log("[session-\(sid)] Opening device: \(device.localizedName) [id=\(currentDeviceID)]")

        let s = AVCaptureSession()

        do {
            let input = try AVCaptureDeviceInput(device: device)
            s.addInput(input)
        } catch {
            log("[session-\(sid)] Error: Could not open mic: \(error.localizedDescription)")
            return false
        }

        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(self, queue: sampleQueue)
        s.addOutput(output)

        log("[session-\(sid)] Starting session...")
        s.startRunning()
        // Reapply after every start so device changes and recovery remain sleep-safe.
        allowSystemIdleSleep()
        session = s
        log("[session-\(sid)] Keeping warm: \(device.localizedName) (isRunning=\(s.isRunning))")
        log("[session-\(sid)] Input format at start: \(inputStreamFormatDescription(currentDeviceID))")

        startHeartbeat(sid: sid, deviceID: currentDeviceID)
        return true
    }

    // MARK: - Sample buffer delegate (runs on sampleQueue)

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        sampleCount += 1
        lastSampleTime = Date()

        if sampleCount == 1 {
            let latency = sessionStartTime.map { Date().timeIntervalSince($0) } ?? 0
            log("[session-\(sessionID)] First sample received (latency: \(String(format: "%.3f", latency))s)")
            log("[session-\(sessionID)] Input format at first sample: \(inputStreamFormatDescription(currentDeviceID))")
            // Reset consecutive zero-sample counter on successful sample delivery
            consecutiveZeroSampleRestarts = 0
        } else if sampleCount == 10 {
            log("[session-\(sessionID)] 10 samples received, stream flowing")
        }

        // Check if audio buffer contains only silence (all zeros).
        // This detects "signal goes flat" where samples keep flowing but are empty.
        if let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) {
            var length = 0
            var dataPointer: UnsafeMutablePointer<Int8>?
            if CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil,
                                           totalLengthOut: &length, dataPointerOut: &dataPointer) == noErr,
               let ptr = dataPointer, length > 0 {
                let isSilent = UnsafeRawPointer(ptr).assumingMemoryBound(to: UInt8.self)
                    .withMemoryRebound(to: UInt8.self, capacity: length) { buf in
                        for i in 0..<length { if buf[i] != 0 { return false } }
                        return true
                    }
                if isSilent {
                    silentSampleCount += 1
                    if silentStreakStart == nil { silentStreakStart = Date() }
                    if flatEpisodeStart == nil { flatEpisodeStart = silentStreakStart }
                    maybeRestartForSilence_onSampleQueue()
                } else {
                    if let start = silentStreakStart {
                        let duration = Date().timeIntervalSince(start)
                        if duration > 2.0 {
                            log("[session-\(sessionID)] Silent streak ended: \(String(format: "%.1f", duration))s (\(silentSampleCount - lastSilentSampleCount) silent buffers)")
                            log("[session-\(sessionID)] [recovery-diag] input format: \(inputStreamFormatDescription(currentDeviceID))")
                            // Capture the BT/coreaudio transition that RESTORED audio. Cover the whole
                            // streak plus a margin so the recovery event is included; compare vs onset.
                            captureSystemAudioBTLog(reason: "SIGNAL recovered session-\(sessionID) after \(String(format: "%.1f", duration))s", seconds: min(Int(duration) + 15, 200))
                            DispatchQueue.global(qos: .utility).async { logAllDevices(prefix: "[recovery-diag]") }
                        }
                    }
                    // Episode summary: the fix-effectiveness metric. Total user-perceived gap
                    // (across any restarts) and how many restarts it took to end it.
                    if let epStart = flatEpisodeStart {
                        let total = Date().timeIntervalSince(epStart)
                        if total > 2.0 || silentRecoveryAttempts > 0 {
                            log("[silent-recovery] Audio restored on session-\(sessionID): flat episode \(String(format: "%.1f", total))s total, \(silentRecoveryAttempts) restart(s)")
                        }
                    }
                    flatEpisodeStart = nil
                    silentRecoveryAttempts = 0
                    lastSilentSampleCount = silentSampleCount
                    silentStreakStart = nil
                    silentDiagCaptured = false
                }
            }
        }
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didDrop sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        log("[session-\(sessionID)] *** DROPPED FRAME (total samples: \(sampleCount))")
    }

    // MARK: - Silent recovery (runs on sampleQueue)

    // Give bluetoothd progressively longer to finish SCO setup before poking it again.
    private func silentRecoveryThreshold(forAttempt attempt: Int) -> TimeInterval {
        return 4.0 + Double(attempt) * 2.0  // 4s, 6s, 8s
    }

    private func maybeRestartForSilence_onSampleQueue() {
        // Bluetooth only: the confirmed flat mechanism is the SCO handoff gap. All-zero
        // buffers on the built-in mic mean something else (e.g. input mute) where a
        // restart would just churn.
        guard currentDeviceIsBluetooth, !silentRestartPending,
              silentRecoveryAttempts < silentRecoveryMaxAttempts,
              let start = silentStreakStart else { return }
        let streak = Date().timeIntervalSince(start)
        guard streak >= silentRecoveryThreshold(forAttempt: silentRecoveryAttempts) else { return }

        // Grab the onset evidence before tearing the session down. `log show --last` is
        // retrospective, so capturing here still covers the onset. Once per episode.
        if !silentDiagCaptured && silentRecoveryAttempts == 0 {
            silentDiagCaptured = true
            DispatchQueue.global(qos: .utility).async { logAllDevices(prefix: "[flat-diag]") }
            captureSystemAudioBTLog(reason: "SIGNAL FLAT onset session-\(sessionID) (pre-restart)", seconds: 45)
        }

        silentRecoveryAttempts += 1
        silentRestartPending = true
        log("[silent-recovery] *** Silent for \(String(format: "%.1f", streak))s on session-\(sessionID); restarting session (attempt \(silentRecoveryAttempts)/\(silentRecoveryMaxAttempts))")
        if silentRecoveryAttempts == silentRecoveryMaxAttempts {
            log("[silent-recovery] Attempt cap reached; further recovery waits for the link to come back on its own")
        }
        sessionQueue.async { self.startSession_onSessionQueue() }
    }

    // MARK: - Heartbeat (runs on sampleQueue)

    private func startHeartbeat(sid: UInt32, deviceID: AudioDeviceID) {
        sampleQueue.async { [self] in
            heartbeatTimer?.cancel()
            lastHeartbeatSampleCount = 0

            let timer = DispatchSource.makeTimerSource(queue: sampleQueue)
            timer.schedule(deadline: .now() + 5.0, repeating: 5.0)
            timer.setEventHandler { [weak self] in
                guard let self, self.sessionID == sid else { return }
                let delta = self.sampleCount - self.lastHeartbeatSampleCount
                let running = self.session?.isRunning ?? false
                let gap = self.lastSampleTime.map { Date().timeIntervalSince($0) } ?? -1

                // Detailed CoreAudio-level state of current device
                let isAlive: UInt32 = deviceID > 0
                    ? (getAudioProperty(deviceID, selector: kAudioDevicePropertyDeviceIsAlive) ?? 0)
                    : 99
                let devRunning: UInt32 = deviceID > 0
                    ? (getAudioProperty(deviceID, selector: kAudioDevicePropertyDeviceIsRunning) ?? 0)
                    : 99
                let runningSomewhere: UInt32 = deviceID > 0
                    ? (getAudioProperty(deviceID, selector: kAudioDevicePropertyDeviceIsRunningSomewhere) ?? 0)
                    : 99
                let hogPID: pid_t = deviceID > 0
                    ? (getAudioProperty(deviceID, selector: kAudioDevicePropertyHogMode) ?? -1)
                    : -1

                if delta == 0 && self.sampleCount > 0 {
                    log("[session-\(sid)] *** HEARTBEAT: NO NEW SAMPLES in 5s (total: \(self.sampleCount), gap: \(String(format: "%.1f", gap))s)")
                    if gap > 15.0 {
                        log("[session-\(sid)] *** AUTO-RECOVERY: samples stopped for \(String(format: "%.0f", gap))s, restarting session")
                        self.sessionQueue.async { self.startSession_onSessionQueue() }
                    }
                } else if delta == 0 && self.sampleCount == 0 {
                    let age = self.sessionStartTime.map { Date().timeIntervalSince($0) } ?? 0
                    log("[session-\(sid)] *** HEARTBEAT: ZERO SAMPLES (sessionRunning=\(running), age: \(String(format: "%.1f", age))s, alive=\(isAlive), devRunning=\(devRunning))")
                    if age > 30.0 && running {
                        self.consecutiveZeroSampleRestarts += 1
                        log("[session-\(sid)] *** AUTO-RECOVERY: zero samples for \(String(format: "%.0f", age))s (consecutive: \(self.consecutiveZeroSampleRestarts)), restarting session")
                        self.sessionQueue.async { self.startSession_onSessionQueue() }
                    }
                } else {
                    let silentDelta = self.silentSampleCount - self.lastSilentSampleCount
                    let silentInfo = silentDelta > 0 ? ", silent=\(silentDelta)/\(delta)" : ""
                    if let start = self.silentStreakStart {
                        let streakDur = Date().timeIntervalSince(start)
                        log("[session-\(sid)] *** HEARTBEAT: SIGNAL FLAT for \(String(format: "%.1f", streakDur))s (+\(delta) samples, \(silentDelta) silent, restarts=\(self.silentRecoveryAttempts), alive=\(isAlive), devRunning=\(devRunning), runningSomewhere=\(runningSomewhere), hogPID=\(hogPID))")
                        log("[session-\(sid)] [flat-diag] input format: \(inputStreamFormatDescription(deviceID))")
                        // Fire the heavy capture once per episode, at first detection, so we grab the
                        // SCO/HFP transition that produced the silence before the unified log rotates
                        // out. Post-restart sessions (attempts > 0) already captured the onset.
                        if !self.silentDiagCaptured && self.silentRecoveryAttempts == 0 {
                            self.silentDiagCaptured = true
                            DispatchQueue.global(qos: .utility).async { logAllDevices(prefix: "[flat-diag]") }
                            captureSystemAudioBTLog(reason: "SIGNAL FLAT onset session-\(sid)", seconds: 45)
                        }
                    } else {
                        log("[session-\(sid)] heartbeat: +\(delta) samples (total: \(self.sampleCount), running=\(running), alive=\(isAlive), devRunning=\(devRunning), runningSomewhere=\(runningSomewhere), hogPID=\(hogPID)\(silentInfo))")
                    }
                    self.lastSilentSampleCount = self.silentSampleCount
                }
                self.lastHeartbeatSampleCount = self.sampleCount
            }
            timer.resume()
            heartbeatTimer = timer
        }
    }

    private func stopHeartbeat_onSampleQueue() {
        sampleQueue.sync {
            heartbeatTimer?.cancel()
            heartbeatTimer = nil
        }
    }

    // MARK: - System-level CoreAudio listeners

    private func installDeviceListener() {
        // Default input device changes. Fires on main (lightweight log + dispatch to sessionQueue).
        var inputAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &inputAddr, DispatchQueue.main
        ) { [weak self] _, _ in
            guard let self else { return }
            let currentDevice = AVCaptureDevice.default(for: .audio)
            let defaultID: AudioDeviceID? = getAudioProperty(
                AudioObjectID(kAudioObjectSystemObject),
                selector: kAudioHardwarePropertyDefaultInputDevice)
            log("[system] Default input device changed -> \(currentDevice?.localizedName ?? "nil") (id=\(defaultID ?? 0))")
            if let did = defaultID {
                log("[system]   New default: \(describeDevice(did))")
            }
            self.debouncedRestart(reason: "default input device changed (new: \(currentDevice?.localizedName ?? "nil"))")
        }

        // Device list changes (additions/removals)
        var devicesAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &devicesAddr, DispatchQueue.main
        ) { _, _ in
            log("[system] *** Device list changed")
            logAllDevices(prefix: "[system]")
        }

        // Default output device changes (relevant for Bluetooth mode switching)
        var outputAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &outputAddr, DispatchQueue.main
        ) { _, _ in
            let outputID: AudioDeviceID? = getAudioProperty(
                AudioObjectID(kAudioObjectSystemObject),
                selector: kAudioHardwarePropertyDefaultOutputDevice)
            if let oid = outputID {
                log("[system] Default output device changed -> \(describeDevice(oid))")
            }
        }
    }

    // Per-device property listeners. Dispatched to listenerQueue (not main, not sessionQueue)
    // to avoid deadlocks. Listeners are tracked for proper cleanup on reinstall.
    private func installPerDeviceListeners() {
        // Clean up old listeners first
        removePerDeviceListeners()

        let devices = getAllAudioDeviceIDs()
        listenerQueue.sync { [self] in
            for deviceID in devices {
                let name = getStringProperty(deviceID, selector: kAudioObjectPropertyName) ?? "?"

                func addListener(_ selector: AudioObjectPropertySelector,
                                 _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                                 handler: @escaping () -> Void) {
                    let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
                    var addr = AudioObjectPropertyAddress(
                        mSelector: selector, mScope: scope,
                        mElement: kAudioObjectPropertyElementMain)
                    AudioObjectAddPropertyListenerBlock(deviceID, &addr, listenerQueue, block)
                    perDeviceListeners.append(ListenerRegistration(
                        deviceID: deviceID, address: addr, block: block))
                }

                addListener(kAudioDevicePropertyDeviceIsAlive) {
                    let alive: UInt32 = getAudioProperty(deviceID, selector: kAudioDevicePropertyDeviceIsAlive) ?? 99
                    log("[device] \(name) [id=\(deviceID)] isAlive changed -> \(alive)")
                }

                addListener(kAudioDevicePropertyDeviceIsRunning) {
                    let running: UInt32 = getAudioProperty(deviceID, selector: kAudioDevicePropertyDeviceIsRunning) ?? 99
                    log("[device] \(name) [id=\(deviceID)] isRunning changed -> \(running)")
                }

                addListener(kAudioDevicePropertyDeviceIsRunningSomewhere) {
                    let rs: UInt32 = getAudioProperty(deviceID, selector: kAudioDevicePropertyDeviceIsRunningSomewhere) ?? 99
                    log("[device] \(name) [id=\(deviceID)] isRunningSomewhere changed -> \(rs)")
                }

                addListener(kAudioDevicePropertyHogMode) {
                    let hog: pid_t = getAudioProperty(deviceID, selector: kAudioDevicePropertyHogMode) ?? -1
                    log("[device] *** \(name) [id=\(deviceID)] hogMode changed -> PID \(hog)")
                }

                addListener(kAudioDevicePropertyDataSource, kAudioObjectPropertyScopeInput) {
                    let src: UInt32 = getAudioProperty(deviceID, selector: kAudioDevicePropertyDataSource,
                                                        scope: kAudioObjectPropertyScopeInput) ?? 0
                    log("[device] \(name) [id=\(deviceID)] input dataSource changed -> \(src)")
                }

                addListener(kAudioDevicePropertyNominalSampleRate) {
                    let rate: Float64 = getAudioProperty(deviceID, selector: kAudioDevicePropertyNominalSampleRate) ?? 0
                    log("[device] \(name) [id=\(deviceID)] sampleRate changed -> \(rate) Hz")
                }

                addListener(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput) {
                    log("[device] \(name) [id=\(deviceID)] input stream configuration changed")
                }
            }
            log("[listeners] Per-device listeners installed for \(devices.count) devices (\(perDeviceListeners.count) total)")
        }
    }

    private func removePerDeviceListeners() {
        listenerQueue.sync { [self] in
            if perDeviceListeners.isEmpty { return }
            var removed = 0
            for var reg in perDeviceListeners {
                let status = AudioObjectRemovePropertyListenerBlock(
                    reg.deviceID, &reg.address, listenerQueue, reg.block)
                if status == noErr { removed += 1 }
            }
            log("[listeners] Removed \(removed)/\(perDeviceListeners.count) per-device listeners")
            perDeviceListeners.removeAll()
        }
    }

    private func installConnectionObservers() {
        let nc = NotificationCenter.default

        let connected: Notification.Name = .AVCaptureDeviceWasConnected
        let disconnected: Notification.Name = .AVCaptureDeviceWasDisconnected
        nc.addObserver(forName: connected, object: nil, queue: .main) {
            [weak self] note in
            if let d = note.object as? AVCaptureDevice, d.hasMediaType(.audio) {
                log("[avfoundation] Device connected: \(d.localizedName)")
                self?.debouncedRestart(reason: "\(d.localizedName) connected")
            }
        }
        nc.addObserver(forName: disconnected, object: nil, queue: .main) {
            [weak self] note in
            if let d = note.object as? AVCaptureDevice, d.hasMediaType(.audio) {
                log("[avfoundation] Device disconnected: \(d.localizedName)")
                self?.debouncedRestart(reason: "\(d.localizedName) disconnected")
            }
        }

        // Session lifecycle notifications
        nc.addObserver(forName: .AVCaptureSessionDidStartRunning, object: nil, queue: .main) {
            [weak self] _ in
            guard let self else { return }
            log("[avfoundation] [session-\(self.sessionID)] AVCaptureSessionDidStartRunning")
        }
        nc.addObserver(forName: .AVCaptureSessionDidStopRunning, object: nil, queue: .main) {
            [weak self] _ in
            guard let self else { return }
            log("[avfoundation] [session-\(self.sessionID)] *** AVCaptureSessionDidStopRunning")
        }
        nc.addObserver(forName: .AVCaptureSessionWasInterrupted, object: nil, queue: .main) {
            [weak self] note in
            guard let self else { return }
            log("[avfoundation] [session-\(self.sessionID)] *** AVCaptureSessionWasInterrupted (userInfo: \(note.userInfo ?? [:]))")
        }
        nc.addObserver(forName: .AVCaptureSessionInterruptionEnded, object: nil, queue: .main) {
            [weak self] _ in
            guard let self else { return }
            log("[avfoundation] [session-\(self.sessionID)] AVCaptureSessionInterruptionEnded")
        }
        nc.addObserver(forName: .AVCaptureSessionRuntimeError, object: nil, queue: .main) {
            [weak self] note in
            guard let self else { return }
            let err = note.userInfo?[AVCaptureSessionErrorKey] as? Error
            log("[avfoundation] [session-\(self.sessionID)] *** AVCaptureSessionRuntimeError: \(err?.localizedDescription ?? "unknown")")
            // Redundant BT capture: this fired during the captured flat episode. Grab the SCO
            // layer here too, in case the flat-heartbeat path hasn't tripped yet.
            captureSystemAudioBTLog(reason: "AVCaptureSessionRuntimeError session-\(self.sessionID): \(err?.localizedDescription ?? "unknown")", seconds: 45)
        }

        // Sleep/wake events. These correlate with Bluetooth disconnections, coreaudiod
        // state resets, and the "signal goes flat" silent-buffer issue on AirPods.
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) {
            [weak self] _ in
            guard let self else { return }
            log("[system] *** SLEEP (session-\(self.sessionID), samples: \(self.sampleCount))")
        }
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) {
            [weak self] _ in
            guard let self else { return }
            log("[system] *** WAKE (session-\(self.sessionID), samples: \(self.sampleCount))")
            logAllDevices(prefix: "[system] [post-wake]")
        }
        ws.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) {
            _ in log("[system] Screens did sleep (lid close or display sleep)")
        }
        ws.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) {
            _ in log("[system] Screens did wake")
        }
    }

    // MARK: - Debounced restart

    private func debouncedRestart(reason: String) {
        sessionQueue.async { [self] in
            debounceWork?.cancel()
            debounceWork = nil
            log("Device event: \(reason) (waiting \(Int(debounceSeconds))s to settle)")
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                log("Debounce fired, restarting session...")
                if self.startSession_onSessionQueue() {
                    log("Restarted after device change")
                    self.installPerDeviceListeners()
                } else {
                    log("No audio device available after change. Waiting for recovery...")
                    self.scheduleRecovery_onSessionQueue()
                }
            }
            debounceWork = work
            sessionQueue.asyncAfter(deadline: .now() + debounceSeconds, execute: work)
        }
    }

    // MARK: - Recovery

    private func scheduleRecovery_onSessionQueue() {
        sessionQueue.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self else { return }
            if self.startSession_onSessionQueue() {
                self.installListenersOnce()
                log("Recovered")
            } else {
                log("Still no audio device. Retrying...")
                self.scheduleRecovery_onSessionQueue()
            }
        }
    }

    // MARK: - Shutdown

    func signalShutdown() {
        // Skip stopRunning() here: it can deadlock on Bluetooth devices, and
        // _exit(0) follows immediately so the OS reclaims all resources.
        session = nil
        cleanupPID()
    }

    func shutdown() {
        debounceWork?.cancel()
        stopHeartbeat_onSampleQueue()
        removePerDeviceListeners()
        // Skip stopRunning(): it can deadlock on Bluetooth devices.
        // Process exit reclaims all resources.
        session = nil
        cleanupPID()
        log("Shutdown complete")
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

log("mic-warm starting (PID: \(ProcessInfo.processInfo.processIdentifier), version: 0.11.0)")
log("[silent-recovery] Enabled: restart Bluetooth session after 4s of silent buffers (max 3 attempts/episode)")
log("[bt-capture] Flat-signal Bluetooth/coreaudio diagnostics enabled -> \(btLogPath)")
log("[bt-capture] Manual trigger: kill -USR1 \(ProcessInfo.processInfo.processIdentifier)")
keeper.start()
// NSApplication.shared.run() services both the GCD main queue (like dispatchMain())
// AND the NSApplication run loop, which is required for NSWorkspace sleep/wake
// notifications. Safe for headless LaunchAgent use.
NSApplication.shared.run()
