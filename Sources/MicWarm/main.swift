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

    // --- Sample state (confined to sampleQueue) ---
    private var sampleCount: UInt64 = 0
    private var lastSampleTime: Date?
    private var lastHeartbeatSampleCount: UInt64 = 0
    private var heartbeatTimer: DispatchSourceTimer?
    // Silent-sample tracking: detects "signal goes flat" (samples flow but contain silence)
    private var silentSampleCount: UInt64 = 0
    private var lastSilentSampleCount: UInt64 = 0
    private var silentStreakStart: Date?

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

        // Reset sample state on sampleQueue
        sampleQueue.sync {
            sampleCount = 0
            silentSampleCount = 0
            lastSilentSampleCount = 0
            silentStreakStart = nil
            lastSampleTime = nil
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
        session = s
        log("[session-\(sid)] Keeping warm: \(device.localizedName) (isRunning=\(s.isRunning))")

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
                } else {
                    if let start = silentStreakStart {
                        let duration = Date().timeIntervalSince(start)
                        if duration > 2.0 {
                            log("[session-\(sessionID)] Silent streak ended: \(String(format: "%.1f", duration))s (\(silentSampleCount - lastSilentSampleCount) silent buffers)")
                        }
                    }
                    lastSilentSampleCount = silentSampleCount
                    silentStreakStart = nil
                }
            }
        }
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didDrop sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        log("[session-\(sessionID)] *** DROPPED FRAME (total samples: \(sampleCount))")
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
                        log("[session-\(sid)] *** HEARTBEAT: SIGNAL FLAT for \(String(format: "%.1f", streakDur))s (+\(delta) samples, \(silentDelta) silent, alive=\(isAlive), devRunning=\(devRunning), runningSomewhere=\(runningSomewhere), hogPID=\(hogPID))")
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
log("mic-warm starting (PID: \(ProcessInfo.processInfo.processIdentifier), version: 0.10.1)")
keeper.start()
// NSApplication.shared.run() services both the GCD main queue (like dispatchMain())
// AND the NSApplication run loop, which is required for NSWorkspace sleep/wake
// notifications. Safe for headless LaunchAgent use.
NSApplication.shared.run()
