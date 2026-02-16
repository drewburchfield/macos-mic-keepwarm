import AVFoundation
import CoreAudio
import Darwin
import Foundation

// MARK: - Logging

// ISO8601DateFormatter is thread-safe, unlike DateFormatter.
// log() is called from both main and background threads (stopRunning watchdog).
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

// MARK: - Capture session

class MicKeeper: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private var session: AVCaptureSession?
    private var debounceWork: DispatchWorkItem?
    private let debounceSeconds: Double = 3.0
    private var listenersInstalled = false

    private var sampleCount: UInt64 = 0
    private var lastSampleTime: Date?
    private var sessionStartTime: Date?
    private var heartbeatTimer: DispatchSourceTimer?
    private var lastHeartbeatSampleCount: UInt64 = 0
    private var sessionID: UInt32 = 0
    private var currentDeviceID: AudioDeviceID = 0

    func start() {
        killStalePID()
        writePID()

        #if false // Enable for instrumented debugging
        log("=== STARTUP DEVICE SNAPSHOT ===")
        logAllDevices(prefix: "[startup]")
        log("=== END STARTUP SNAPSHOT ===")
        #endif

        guard startSession() else {
            log("Error: No audio input device found. Waiting for recovery...")
            scheduleRecovery()
            return
        }

        installListenersOnce()
    }

    private func installListenersOnce() {
        guard !listenersInstalled else { return }
        listenersInstalled = true
        installDeviceListener()
        installConnectionObservers()
        #if false // Enable for instrumented debugging
        installPerDeviceListeners()
        #endif
        log("[listeners] All system listeners installed")
    }

    // Start (or restart) the capture session on the current default mic.
    @discardableResult
    func startSession() -> Bool {
        // Cancel any pending debounced restart (e.g. if auto-recovery fires first)
        debounceWork?.cancel()
        debounceWork = nil

        if let old = session {
            let oldSid = sessionID
            let oldSamples = sampleCount
            log("[session-\(oldSid)] Stopping old session (samples received: \(oldSamples))")
            #if false // Enable for instrumented debugging
            old.removeObserver(self, forKeyPath: "running")
            #endif
            // Tear down the audio pipeline on the main thread before dispatching
            // stopRunning(). The CMIO graph holds a semaphore that coreaudiod's
            // AudioDeviceManager thread waits on; removing inputs/outputs releases
            // that graph and frees the semaphore, reducing the chance that a
            // background stopRunning() deadlocks on a disconnected Bluetooth device.
            for output in old.outputs {
                if let audioOutput = output as? AVCaptureAudioDataOutput {
                    audioOutput.setSampleBufferDelegate(nil, queue: nil)
                }
                old.removeOutput(output)
            }
            for input in old.inputs {
                old.removeInput(input)
            }
            // Stop the old session on a background thread. Even with inputs/outputs
            // removed, stopRunning() can still hang if CoreAudio's HALB_Guard is
            // waiting on a condition variable for the dead Bluetooth device.
            DispatchQueue.global(qos: .utility).async {
                log("[session-\(oldSid)] Background: stopping old session...")
                old.stopRunning()
                log("[session-\(oldSid)] Background: old session stopped")
            }
            // Watchdog: warn if stopRunning() hangs (likely deadlocked on dead device)
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 10.0) { [weak old] in
                if let old, old.isRunning {
                    log("[session-\(oldSid)] WARNING: stopRunning() did not complete in 10s (likely deadlocked on dead Bluetooth device)")
                }
            }
        }
        session = nil
        stopHeartbeat()

        sampleCount = 0
        lastSampleTime = nil
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
        #if false // Enable for instrumented debugging
        s.addObserver(self, forKeyPath: "running", options: [.new, .old], context: nil)
        #endif

        do {
            let input = try AVCaptureDeviceInput(device: device)
            s.addInput(input)
        } catch {
            log("[session-\(sid)] Error: Could not open mic: \(error.localizedDescription)")
            return false
        }

        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(self, queue: .main)
        s.addOutput(output)

        log("[session-\(sid)] Starting session...")
        s.startRunning()
        session = s
        log("[session-\(sid)] Keeping warm: \(device.localizedName) (isRunning=\(s.isRunning))")

        startHeartbeat(sid: sid)
        return true
    }

    #if false // Enable for instrumented debugging
    // KVO observer for session running state
    override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                               change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        if keyPath == "running", let newVal = change?[.newKey] as? Bool {
            let oldVal = change?[.oldKey] as? Bool ?? false
            log("[session-\(sessionID)] isRunning changed: \(oldVal) -> \(newVal) (samples: \(sampleCount))")
            if !newVal && oldVal {
                log("[session-\(sessionID)] *** SESSION STOPPED (samples: \(sampleCount))")
                logAllDevices(prefix: "[session-\(sessionID) STOPPED]")
            }
        }
    }
    #endif

    // AVCaptureAudioDataOutputSampleBufferDelegate
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        sampleCount += 1
        lastSampleTime = Date()

        #if false // Enable for instrumented debugging
        if sampleCount == 1 {
            let latency = sessionStartTime.map { Date().timeIntervalSince($0) } ?? 0
            log("[session-\(sessionID)] First sample received (latency: \(String(format: "%.3f", latency))s)")
        } else if sampleCount == 10 {
            log("[session-\(sessionID)] 10 samples received, stream flowing")
        }
        #endif
    }

    #if false // Enable for instrumented debugging
    func captureOutput(_ output: AVCaptureOutput,
                       didDrop sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        log("[session-\(sessionID)] *** DROPPED FRAME (total samples: \(sampleCount))")
    }
    #endif

    // MARK: - Heartbeat

    private func startHeartbeat(sid: UInt32) {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 5.0, repeating: 5.0)
        timer.setEventHandler { [weak self] in
            guard let self, self.sessionID == sid else { return }
            let delta = self.sampleCount - self.lastHeartbeatSampleCount
            let running = self.session?.isRunning ?? false
            let gap = self.lastSampleTime.map { Date().timeIntervalSince($0) } ?? -1

            #if false // Enable for instrumented debugging
            // Detailed CoreAudio-level state of current device
            let isAlive: UInt32 = self.currentDeviceID > 0
                ? (getAudioProperty(self.currentDeviceID, selector: kAudioDevicePropertyDeviceIsAlive) ?? 0)
                : 99
            let isRunning: UInt32 = self.currentDeviceID > 0
                ? (getAudioProperty(self.currentDeviceID, selector: kAudioDevicePropertyDeviceIsRunning) ?? 0)
                : 99
            let runningSomewhere: UInt32 = self.currentDeviceID > 0
                ? (getAudioProperty(self.currentDeviceID, selector: kAudioDevicePropertyDeviceIsRunningSomewhere) ?? 0)
                : 99
            let hogPID: pid_t = self.currentDeviceID > 0
                ? (getAudioProperty(self.currentDeviceID, selector: kAudioDevicePropertyHogMode) ?? -1)
                : -1
            #endif

            if delta == 0 && self.sampleCount > 0 {
                log("[session-\(sid)] *** HEARTBEAT: NO NEW SAMPLES in 5s (total: \(self.sampleCount), gap: \(String(format: "%.1f", gap))s)")
                // Auto-recover if samples stopped for >15s
                if gap > 15.0 {
                    log("[session-\(sid)] *** AUTO-RECOVERY: samples stopped for \(String(format: "%.0f", gap))s, restarting session")
                    self.startSession()
                }
            } else if delta == 0 && self.sampleCount == 0 {
                let age = self.sessionStartTime.map { Date().timeIntervalSince($0) } ?? 0
                log("[session-\(sid)] *** HEARTBEAT: ZERO SAMPLES (sessionRunning=\(running), age: \(String(format: "%.1f", age))s)")
                // Auto-recover if zero samples for >30s (allows time for TCC dialog)
                if age > 30.0 && running {
                    log("[session-\(sid)] *** AUTO-RECOVERY: zero samples for \(String(format: "%.0f", age))s, restarting session")
                    self.startSession()
                }
            }
            // Normal heartbeat logging (only in instrumented builds):
            // else { log("[session-\(sid)] heartbeat: +\(delta) samples ...") }
            self.lastHeartbeatSampleCount = self.sampleCount
        }
        timer.resume()
        heartbeatTimer = timer
        lastHeartbeatSampleCount = 0
    }

    private func stopHeartbeat() {
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
    }

    // MARK: - System-level CoreAudio listeners

    private func installDeviceListener() {
        // Default input device changes
        var inputAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &inputAddr, DispatchQueue.main
        ) { [weak self] _, _ in
            guard let self else { return }
            let currentDevice = AVCaptureDevice.default(for: .audio)
            #if false // Enable for instrumented debugging
            let defaultID: AudioDeviceID? = getAudioProperty(
                AudioObjectID(kAudioObjectSystemObject),
                selector: kAudioHardwarePropertyDefaultInputDevice)
            log("[system] Default input device changed -> \(currentDevice?.localizedName ?? "nil") (id=\(defaultID ?? 0))")
            if let did = defaultID {
                log("[system]   New default: \(describeDevice(did))")
            }
            #endif
            self.debouncedRestart(reason: "default input device changed (new: \(currentDevice?.localizedName ?? "nil"))")
        }

        #if false // Enable for instrumented debugging
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
        #endif
    }

    #if false // Enable for instrumented debugging
    // Per-device property listeners for every audio device
    private func installPerDeviceListeners() {
        let devices = getAllAudioDeviceIDs()
        for deviceID in devices {
            let name = getStringProperty(deviceID, selector: kAudioObjectPropertyName) ?? "?"

            // Device alive state
            var aliveAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceIsAlive,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(deviceID, &aliveAddr, DispatchQueue.main) { _, _ in
                let alive: UInt32 = getAudioProperty(deviceID, selector: kAudioDevicePropertyDeviceIsAlive) ?? 99
                log("[device] \(name) [id=\(deviceID)] isAlive changed -> \(alive)")
            }

            // Device running state
            var runningAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceIsRunning,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(deviceID, &runningAddr, DispatchQueue.main) { _, _ in
                let running: UInt32 = getAudioProperty(deviceID, selector: kAudioDevicePropertyDeviceIsRunning) ?? 99
                log("[device] \(name) [id=\(deviceID)] isRunning changed -> \(running)")
            }

            // Device running somewhere (any process)
            var runningSomewhereAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(deviceID, &runningSomewhereAddr, DispatchQueue.main) { _, _ in
                let rs: UInt32 = getAudioProperty(deviceID, selector: kAudioDevicePropertyDeviceIsRunningSomewhere) ?? 99
                log("[device] \(name) [id=\(deviceID)] isRunningSomewhere changed -> \(rs)")
            }

            // Hog mode (exclusive access)
            var hogAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyHogMode,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(deviceID, &hogAddr, DispatchQueue.main) { _, _ in
                let hog: pid_t = getAudioProperty(deviceID, selector: kAudioDevicePropertyHogMode) ?? -1
                log("[device] *** \(name) [id=\(deviceID)] hogMode changed -> PID \(hog)")
            }

            // Data source changes (relevant for input source switching)
            var dataSourceAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDataSource,
                mScope: kAudioObjectPropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(deviceID, &dataSourceAddr, DispatchQueue.main) { _, _ in
                let src: UInt32 = getAudioProperty(deviceID, selector: kAudioDevicePropertyDataSource,
                                                    scope: kAudioObjectPropertyScopeInput) ?? 0
                log("[device] \(name) [id=\(deviceID)] input dataSource changed -> \(src)")
            }

            // Nominal sample rate changes (Bluetooth codec switches)
            var rateAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyNominalSampleRate,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(deviceID, &rateAddr, DispatchQueue.main) { _, _ in
                let rate: Float64 = getAudioProperty(deviceID, selector: kAudioDevicePropertyNominalSampleRate) ?? 0
                log("[device] \(name) [id=\(deviceID)] sampleRate changed -> \(rate) Hz")
            }

            // Stream configuration changes
            var streamAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: kAudioObjectPropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(deviceID, &streamAddr, DispatchQueue.main) { _, _ in
                log("[device] \(name) [id=\(deviceID)] input stream configuration changed")
            }

            // Device "has changed" (generic catch-all)
            var changedAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceHasChanged,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(deviceID, &changedAddr, DispatchQueue.main) { _, _ in
                log("[device] \(name) [id=\(deviceID)] deviceHasChanged fired")
            }
        }
        log("[listeners] Per-device listeners installed for \(devices.count) devices")
    }
    #endif

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

        #if false // Enable for instrumented debugging
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
            logAllDevices(prefix: "[avfoundation] [session-\(self.sessionID) STOPPED]")
        }
        nc.addObserver(forName: .AVCaptureSessionWasInterrupted, object: nil, queue: .main) {
            [weak self] note in
            guard let self else { return }
            log("[avfoundation] [session-\(self.sessionID)] *** AVCaptureSessionWasInterrupted (userInfo: \(note.userInfo ?? [:]))")
            logAllDevices(prefix: "[avfoundation] [session-\(self.sessionID) INTERRUPTED]")
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
            logAllDevices(prefix: "[avfoundation] [session-\(self.sessionID) ERROR]")
        }
        #endif
    }

    private func debouncedRestart(reason: String) {
        debounceWork?.cancel()
        debounceWork = nil
        log("Device event: \(reason) (waiting \(Int(debounceSeconds))s to settle)")
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            log("Debounce fired, restarting session...")
            if self.startSession() {
                log("Restarted after device change")
                #if false // Enable for instrumented debugging
                self.installPerDeviceListeners()
                #endif
            } else {
                log("No audio device available after change. Waiting for recovery...")
                self.scheduleRecovery()
            }
        }
        debounceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceSeconds, execute: work)
    }

    // MARK: - Recovery

    private func scheduleRecovery() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self else { return }
            if self.startSession() {
                self.installListenersOnce()
                log("Recovered")
            } else {
                log("Still no audio device. Retrying...")
                self.scheduleRecovery()
            }
        }
    }

    func signalShutdown() {
        // Skip stopRunning() here: it can deadlock on Bluetooth devices, and
        // _exit(0) follows immediately so the OS reclaims all resources.
        session = nil
        cleanupPID()
    }

    func shutdown() {
        debounceWork?.cancel()
        stopHeartbeat()
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
log("mic-warm starting (PID: \(ProcessInfo.processInfo.processIdentifier), version: 0.9.2)")
keeper.start()
dispatchMain()
