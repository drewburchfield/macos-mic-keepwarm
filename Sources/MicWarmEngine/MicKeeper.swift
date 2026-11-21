import AppKit
import AVFoundation
import CoreAudio
import Darwin
import Foundation
import MicWarmCore

// MARK: - Per-device listener tracking

// Per-device listeners use the C-function API, not AudioObjectAddPropertyListenerBlock.
// Removing a block listener needs the identical block object, and a Swift closure does not
// keep that identity across the add and remove calls. The HAL still returns noErr, so every
// reinstall silently stacked another copy (one property change logged 88 times in the same
// millisecond after 88 reinstalls). A fixed proc plus clientData pair removes reliably.
struct ListenerRegistration {
    let deviceID: AudioObjectID
    var address: AudioObjectPropertyAddress
}

private let perDeviceListenerProc: AudioObjectPropertyListenerProc = { objectID, count, addresses, clientData in
    guard let clientData else { return noErr }
    let keeper = Unmanaged<MicKeeper>.fromOpaque(clientData).takeUnretainedValue()
    let changed = (0..<Int(count)).map { addresses[$0] }
    keeper.perDevicePropertiesChanged(objectID, changed)
    return noErr
}

// MARK: - Capture session

/// What the keeper is doing, for a UI. Reported on the main queue, only when it changes.
public enum KeeperStatus: Equatable {
    /// A session is open; no buffers have arrived yet.
    case starting
    /// Buffers are arriving with signal in them.
    case warm
    /// The signal went flat or stopped and the session is restarting or waiting it out.
    case recovering
    /// No input device could be opened. Retrying.
    case noDevice
    /// Released on request (`pause()`).
    case paused
}

public final class MicKeeper: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {

    /// Called on the main queue with the new status and the current input device's name.
    public var onStatusChange: ((KeeperStatus, String?) -> Void)?

    // Status is written from the session and sample queues; the lock keeps compare-and-set atomic.
    private let statusLock = NSLock()
    private var status: KeeperStatus = .starting
    private var deviceName: String?

    /// The current status and device name, readable from any queue.
    public var currentStatus: (status: KeeperStatus, device: String?) {
        statusLock.lock(); defer { statusLock.unlock() }
        return (status, deviceName)
    }

    private func setStatus(_ requested: KeeperStatus, device: String?? = nil) {
        statusLock.lock()
        // A restart in the middle of recovery is not a recovery: stay "recovering" until
        // signal actually arrives.
        let new: KeeperStatus = requested == .starting && status == .recovering ? .recovering : requested
        let changed = new != status || (device != nil && device! != deviceName)
        status = new
        if let device { deviceName = device }
        let name = deviceName
        statusLock.unlock()
        guard changed else { return }
        DispatchQueue.main.async { [weak self] in self?.onStatusChange?(new, name) }
    }

    // Set by pause()/resume() on sessionQueue. While paused, nothing reopens the mic.
    private var paused = false

    // --- Queues ---
    // Session lifecycle: create, teardown, configure, restart. Never use main for these.
    private let sessionQueue = DispatchQueue(label: "com.micwarm.session")
    // Sample buffer delivery and heartbeat. Confines all sample counting state.
    private let sampleQueue = DispatchQueue(label: "com.micwarm.samples", qos: .userInteractive)
    // CoreAudio per-device listener callbacks. Isolated from both main and session queues.
    private let listenerQueue = DispatchQueue(label: "com.micwarm.listeners")

    // --- Session state (written on sessionQueue; sessionID and the device fields are also read,
    // unsynchronized, by sampleQueue and main for logging) ---
    private var session: AVCaptureSession?
    private var debounceWork: DispatchWorkItem?
    private let debounceSeconds: Double = 3.0
    private var listenersInstalled = false
    private var sessionID: UInt32 = 0
    private var currentDeviceID: AudioDeviceID = 0
    private var sessionStartTime: Date?

    // --- Sample state (confined to sampleQueue; sleep/wake observers on main read sampleCount for logging) ---
    private var sampleCount: UInt64 = 0
    private var consecutiveZeroSampleRestarts: Int = 0
    private var currentDeviceIsBluetooth: Bool = false
    private var lastSampleTime: Date?
    private var lastHeartbeatSampleCount: UInt64 = 0
    private var heartbeatTimer: DispatchSourceTimer?
    // Silent-sample tracking: detects "signal goes flat" (samples flow but contain silence)
    private var silentSampleCount: UInt64 = 0
    private var lastSilentSampleCount: UInt64 = 0
    private var silentStreakStart: Date?
    // Ensures the heavy flat-onset diagnostic capture fires only once per silent streak.
    private var silentDiagCaptured: Bool = false
    // Silent-recovery episode (see SilentRecoveryEpisode). Survives startSession's
    // per-session reset. Confined to sampleQueue.
    private var flatEpisode = SilentRecoveryEpisode()

    // --- Listener tracking (confined to listenerQueue) ---
    private var perDeviceListeners: [ListenerRegistration] = []
    private var perDeviceNames: [AudioObjectID: String] = [:]

    // MARK: - Startup

    public override init() { super.init() }

    /// Opens the default mic and installs the system listeners. The host takes the instance
    /// lock first. With `paused`, only the listeners go in and the mic stays closed until `resume()`.
    public func start(paused startPaused: Bool = false) {
        log("=== STARTUP DEVICE SNAPSHOT ===")
        logAllDevices(prefix: "[startup]")
        log("=== END STARTUP SNAPSHOT ===")

        sessionQueue.async { [self] in
            if startPaused {
                paused = true
                log("Starting paused; the mic stays closed until resumed")
                setStatus(.paused)
                installListenersOnce()
                return
            }
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

    // Close the current session, if any, and stop its heartbeat. MUST be called on sessionQueue.
    private func teardownSession_onSessionQueue() {
        // Cancel any pending debounced restart
        debounceWork?.cancel()
        debounceWork = nil

        // Tear down old session synchronously. Because we are on sessionQueue (not main),
        // CoreAudio's dispatch_sync(main) for property notifications can still complete,
        // avoiding the CAGuard deadlock that plagued the main-thread approach.
        if let old = session {
            let oldSid = sessionID
            let oldSamples = sampleQueue.sync { sampleCount }
            log("[session-\(oldSid)] Stopping old session (samples received: \(oldSamples))")

            // Detach delegate first so no new sample callbacks are scheduled.
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
    }

    // MARK: - Pause

    /// Closes the mic and keeps it closed (device changes and recovery included) until `resume()`.
    /// `released`, if given, runs on the main queue once the mic is closed.
    public func pause(released: (() -> Void)? = nil) {
        sessionQueue.async { [self] in
            if !paused {
                paused = true
                log("Paused: releasing the mic")
                teardownSession_onSessionQueue()
                setStatus(.paused)
            }
            if let released { DispatchQueue.main.async(execute: released) }
        }
    }

    /// Reopens the default mic after `pause()`.
    public func resume() {
        sessionQueue.async { [self] in
            guard paused else { return }
            paused = false
            log("Resumed: reopening the mic")
            if !startSession_onSessionQueue() {
                scheduleRecovery_onSessionQueue()
            }
            installListenersOnce()
        }
    }

    // Start (or restart) the capture session on the current default mic.
    // MUST be called on sessionQueue.
    @discardableResult
    private func startSession_onSessionQueue() -> Bool {
        teardownSession_onSessionQueue()

        // Reset sample state on sampleQueue. The flat episode deliberately survives:
        // it tracks a flat episode across restarts.
        sampleQueue.sync {
            sampleCount = 0
            silentSampleCount = 0
            lastSilentSampleCount = 0
            silentStreakStart = nil
            lastSampleTime = nil
            silentDiagCaptured = false
            flatEpisode.sessionStarted()
        }

        sessionStartTime = Date()
        sessionID += 1
        let sid = sessionID

        guard let device = AVCaptureDevice.default(for: .audio) else {
            log("[session-\(sid)] No default audio device found")
            setStatus(.noDevice, device: .some(nil))
            return false
        }

        // Get CoreAudio device ID for this AVCaptureDevice
        currentDeviceID = getAllAudioDeviceIDs().first {
            getStringProperty($0, selector: kAudioDevicePropertyDeviceUID) == device.uniqueID
        } ?? 0

        let transport: UInt32 = currentDeviceID > 0
            ? (getAudioProperty(currentDeviceID, selector: kAudioDevicePropertyTransportType) ?? 0)
            : 0
        let isBluetooth = transport == kAudioDeviceTransportTypeBluetooth
            || transport == kAudioDeviceTransportTypeBluetoothLE
        // Read by silent recovery on sampleQueue.
        sampleQueue.sync { currentDeviceIsBluetooth = isBluetooth }

        log("[session-\(sid)] Opening device: \(device.localizedName) [id=\(currentDeviceID)]")

        let s = AVCaptureSession()

        do {
            let input = try AVCaptureDeviceInput(device: device)
            s.addInput(input)
        } catch {
            log("[session-\(sid)] Error: Could not open mic: \(error.localizedDescription)")
            setStatus(.noDevice, device: .some(device.localizedName))
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
        setStatus(.starting, device: .some(device.localizedName))
        log("[session-\(sid)] Input format at start: \(inputStreamFormatDescription(currentDeviceID))")

        startHeartbeat(sid: sid, deviceID: currentDeviceID)
        return true
    }

    // MARK: - Sample buffer delegate (runs on sampleQueue)

    public func captureOutput(_ output: AVCaptureOutput,
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
        if let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer),
           let isSilent = AudioSilence.isAllZero(blockBuffer) {
            if isSilent {
                silentSampleCount += 1
                if silentStreakStart == nil { silentStreakStart = Date() }
                if let streakStart = silentStreakStart { flatEpisode.silentBuffer(streakStart: streakStart) }
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
                if let summary = flatEpisode.audioRestored(now: Date()) {
                    log("[silent-recovery] Audio restored on session-\(sessionID): flat episode \(String(format: "%.1f", summary.total))s total, \(summary.restarts) restart(s)")
                }
                lastSilentSampleCount = silentSampleCount
                silentStreakStart = nil
                silentDiagCaptured = false
                setStatus(.warm)
            }
        }
    }

    public func captureOutput(_ output: AVCaptureOutput,
                       didDrop sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        log("[session-\(sessionID)] *** DROPPED FRAME (total samples: \(sampleCount))")
    }

    // MARK: - Silent recovery (runs on sampleQueue)

    private func maybeRestartForSilence_onSampleQueue() {
        guard let start = silentStreakStart else { return }
        let now = Date()
        guard let attempt = flatEpisode.restartAttempt(
            isBluetooth: currentDeviceIsBluetooth, streakStart: start, now: now) else { return }
        let streak = now.timeIntervalSince(start)

        // Grab the onset evidence before tearing the session down. `log show --last` is
        // retrospective, so capturing here still covers the onset. Once per episode.
        if !silentDiagCaptured && attempt == 1 {
            silentDiagCaptured = true
            DispatchQueue.global(qos: .utility).async { logAllDevices(prefix: "[flat-diag]") }
            captureSystemAudioBTLog(reason: "SIGNAL FLAT onset session-\(sessionID) (pre-restart)", seconds: 45)
        }

        setStatus(.recovering)
        let maxAttempts = SilentRecoveryEpisode.maxAttempts
        log("[silent-recovery] *** Silent for \(String(format: "%.1f", streak))s on session-\(sessionID); restarting session (attempt \(attempt)/\(maxAttempts))")
        if attempt == maxAttempts {
            log("[silent-recovery] Attempt cap reached; further recovery waits for the link to come back on its own")
        }
        sessionQueue.async { self.restartOrRecover_onSessionQueue(reason: "silent-recovery") }
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
                    self.setStatus(.recovering)
                    if gap > 15.0 {
                        log("[session-\(sid)] *** AUTO-RECOVERY: samples stopped for \(String(format: "%.0f", gap))s, restarting session")
                        self.sessionQueue.async { self.restartOrRecover_onSessionQueue(reason: "samples stopped") }
                    }
                } else if delta == 0 && self.sampleCount == 0 {
                    let age = self.sessionStartTime.map { Date().timeIntervalSince($0) } ?? 0
                    log("[session-\(sid)] *** HEARTBEAT: ZERO SAMPLES (sessionRunning=\(running), age: \(String(format: "%.1f", age))s, alive=\(isAlive), devRunning=\(devRunning))")
                    self.setStatus(.recovering)
                    if age > 30.0 && running {
                        self.consecutiveZeroSampleRestarts += 1
                        log("[session-\(sid)] *** AUTO-RECOVERY: zero samples for \(String(format: "%.0f", age))s (consecutive: \(self.consecutiveZeroSampleRestarts)), restarting session")
                        self.sessionQueue.async { self.restartOrRecover_onSessionQueue(reason: "zero samples") }
                    }
                } else {
                    let silentDelta = self.silentSampleCount - self.lastSilentSampleCount
                    let silentInfo = silentDelta > 0 ? ", silent=\(silentDelta)/\(delta)" : ""
                    if let start = self.silentStreakStart {
                        let streakDur = Date().timeIntervalSince(start)
                        if self.currentDeviceIsBluetooth && streakDur >= SilentRecoveryEpisode.threshold(forAttempt: 0) {
                            self.setStatus(.recovering)
                        }
                        log("[session-\(sid)] *** HEARTBEAT: SIGNAL FLAT for \(String(format: "%.1f", streakDur))s (+\(delta) samples, \(silentDelta) silent, restarts=\(self.flatEpisode.attempts), alive=\(isAlive), devRunning=\(devRunning), runningSomewhere=\(runningSomewhere), hogPID=\(hogPID))")
                        log("[session-\(sid)] [flat-diag] input format: \(inputStreamFormatDescription(deviceID))")
                        // Fire the heavy capture once per episode, at first detection, so we grab the
                        // SCO/HFP transition that produced the silence before the unified log rotates
                        // out. Post-restart sessions (attempts > 0) already captured the onset.
                        if !self.silentDiagCaptured && self.flatEpisode.attempts == 0 {
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

    // Per-device property listeners. The HAL calls perDeviceListenerProc on its own thread;
    // the work hops to listenerQueue (not main, not sessionQueue) to avoid deadlocks.
    // Listeners are tracked for proper cleanup on reinstall.
    private static let perDeviceProperties: [(AudioObjectPropertySelector, AudioObjectPropertyScope)] = [
        (kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal),
        (kAudioDevicePropertyDeviceIsRunning, kAudioObjectPropertyScopeGlobal),
        (kAudioDevicePropertyDeviceIsRunningSomewhere, kAudioObjectPropertyScopeGlobal),
        (kAudioDevicePropertyHogMode, kAudioObjectPropertyScopeGlobal),
        (kAudioDevicePropertyDataSource, kAudioObjectPropertyScopeInput),
        (kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal),
        (kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput),
    ]

    // MicKeeper lives for the whole process, so an unretained pointer is a stable clientData.
    private var listenerClientData: UnsafeMutableRawPointer {
        Unmanaged.passUnretained(self).toOpaque()
    }

    private func installPerDeviceListeners() {
        // Clean up old listeners first
        removePerDeviceListeners()

        let devices = getAllAudioDeviceIDs()
        listenerQueue.sync { [self] in
            for deviceID in devices {
                perDeviceNames[deviceID] = getStringProperty(deviceID, selector: kAudioObjectPropertyName) ?? "?"
                for (selector, scope) in Self.perDeviceProperties {
                    var addr = AudioObjectPropertyAddress(
                        mSelector: selector, mScope: scope,
                        mElement: kAudioObjectPropertyElementMain)
                    let status = AudioObjectAddPropertyListener(
                        deviceID, &addr, perDeviceListenerProc, listenerClientData)
                    if status == noErr {
                        perDeviceListeners.append(ListenerRegistration(deviceID: deviceID, address: addr))
                    } else {
                        log("[listeners] Add failed for \(perDeviceNames[deviceID] ?? "?") [id=\(deviceID)] selector=\(selector) status=\(status)")
                    }
                }
            }
            log("[listeners] Per-device listeners installed for \(devices.count) devices (\(perDeviceListeners.count) total)")
        }
    }

    // Called by perDeviceListenerProc on a HAL thread.
    fileprivate func perDevicePropertiesChanged(_ deviceID: AudioObjectID,
                                                _ addresses: [AudioObjectPropertyAddress]) {
        listenerQueue.async { [self] in
            let name = perDeviceNames[deviceID] ?? "?"
            for addr in addresses {
                switch addr.mSelector {
                case kAudioDevicePropertyDeviceIsAlive:
                    let alive: UInt32 = getAudioProperty(deviceID, selector: kAudioDevicePropertyDeviceIsAlive) ?? 99
                    log("[device] \(name) [id=\(deviceID)] isAlive changed -> \(alive)")
                case kAudioDevicePropertyDeviceIsRunning:
                    let running: UInt32 = getAudioProperty(deviceID, selector: kAudioDevicePropertyDeviceIsRunning) ?? 99
                    log("[device] \(name) [id=\(deviceID)] isRunning changed -> \(running)")
                case kAudioDevicePropertyDeviceIsRunningSomewhere:
                    let rs: UInt32 = getAudioProperty(deviceID, selector: kAudioDevicePropertyDeviceIsRunningSomewhere) ?? 99
                    log("[device] \(name) [id=\(deviceID)] isRunningSomewhere changed -> \(rs)")
                case kAudioDevicePropertyHogMode:
                    let hog: pid_t = getAudioProperty(deviceID, selector: kAudioDevicePropertyHogMode) ?? -1
                    log("[device] *** \(name) [id=\(deviceID)] hogMode changed -> PID \(hog)")
                case kAudioDevicePropertyDataSource:
                    let src: UInt32 = getAudioProperty(deviceID, selector: kAudioDevicePropertyDataSource,
                                                        scope: kAudioObjectPropertyScopeInput) ?? 0
                    log("[device] \(name) [id=\(deviceID)] input dataSource changed -> \(src)")
                case kAudioDevicePropertyNominalSampleRate:
                    let rate: Float64 = getAudioProperty(deviceID, selector: kAudioDevicePropertyNominalSampleRate) ?? 0
                    log("[device] \(name) [id=\(deviceID)] sampleRate changed -> \(rate) Hz")
                case kAudioDevicePropertyStreamConfiguration:
                    log("[device] \(name) [id=\(deviceID)] input stream configuration changed")
                default:
                    break
                }
            }
        }
    }

    private func removePerDeviceListeners() {
        listenerQueue.sync { [self] in
            if perDeviceListeners.isEmpty { return }
            // Removal fails with kAudioHardwareBadObjectError for devices that already went
            // away; the HAL drops their listeners with the device, so that count is expected.
            var removed = 0
            for var reg in perDeviceListeners {
                let status = AudioObjectRemovePropertyListener(
                    reg.deviceID, &reg.address, perDeviceListenerProc, listenerClientData)
                if status == noErr { removed += 1 }
            }
            log("[listeners] Removed \(removed)/\(perDeviceListeners.count) per-device listeners")
            perDeviceListeners.removeAll()
            perDeviceNames.removeAll()
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
                guard let self, !self.paused else { return }
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

    // startSession tears down the old session (and its heartbeat) before opening the device.
    // If the open fails, e.g. mid Bluetooth handoff, nothing else would retry, so fall back to
    // the recovery loop.
    private func restartOrRecover_onSessionQueue(reason: String) {
        guard !paused else { return }
        if !startSession_onSessionQueue() {
            log("[recovery] Restart failed (\(reason)); retrying until a device opens")
            scheduleRecovery_onSessionQueue()
        }
    }

    private func scheduleRecovery_onSessionQueue() {
        sessionQueue.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self, !self.paused else { return }
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

    public func signalShutdown() {
        // Skip stopRunning() here: it can deadlock on Bluetooth devices, and
        // _exit(0) follows immediately so the OS reclaims all resources (the
        // instance lock included).
        session = nil
    }
}

