import AVFoundation
import CoreAudio
import Darwin
import Foundation

// MARK: - Logging

func log(_ msg: String) {
    let ts = DateFormatter()
    ts.dateFormat = "HH:mm:ss"
    print("[\(ts.string(from: Date()))] \(msg)")
    fflush(stdout)
}

// MARK: - PID file

let pidPath = "/tmp/mic-warm.pid"

func writePID() {
    try? "\(ProcessInfo.processInfo.processIdentifier)".write(
        toFile: pidPath, atomically: true, encoding: .utf8)
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

    func start() {
        killStalePID()
        writePID()

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
    }

    // Start (or restart) the capture session on the current default mic.
    @discardableResult
    func startSession() -> Bool {
        session?.stopRunning()
        session = nil

        guard let device = AVCaptureDevice.default(for: .audio) else {
            return false
        }

        let s = AVCaptureSession()
        do {
            let input = try AVCaptureDeviceInput(device: device)
            s.addInput(input)
        } catch {
            log("Error: Could not open mic: \(error.localizedDescription)")
            return false
        }

        // A delegate is required for the session to actually activate the hardware.
        let output = AVCaptureAudioDataOutput()
        let queue = DispatchQueue(label: "mic-warm.audio", qos: .userInitiated)
        output.setSampleBufferDelegate(self, queue: queue)
        s.addOutput(output)

        s.startRunning()
        session = s
        log("Keeping warm: \(device.localizedName)")
        return true
    }

    // AVCaptureAudioDataOutputSampleBufferDelegate - discard all samples.
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {}

    // MARK: - Device change detection

    private func installDeviceListener() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)

        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main
        ) { [weak self] _, _ in
            self?.debouncedRestart(reason: "default input device changed")
        }
    }

    private func installConnectionObservers() {
        let nc = NotificationCenter.default
        // Use the pre-macOS 15 names for SDK compatibility (Xcode 15.x).
        // These still work on macOS 15+ despite being marked deprecated.
        let connected: Notification.Name = .AVCaptureDeviceWasConnected
        let disconnected: Notification.Name = .AVCaptureDeviceWasDisconnected
        nc.addObserver(forName: connected, object: nil, queue: .main) {
            [weak self] note in
            if let d = note.object as? AVCaptureDevice, d.hasMediaType(.audio) {
                self?.debouncedRestart(reason: "\(d.localizedName) connected")
            }
        }
        nc.addObserver(forName: disconnected, object: nil, queue: .main) {
            [weak self] note in
            if let d = note.object as? AVCaptureDevice, d.hasMediaType(.audio) {
                self?.debouncedRestart(reason: "\(d.localizedName) disconnected")
            }
        }
    }

    private func debouncedRestart(reason: String) {
        debounceWork?.cancel()
        debounceWork = nil
        log("Device event: \(reason) (waiting \(Int(debounceSeconds))s to settle)")
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.startSession() {
                log("Restarted after device change")
            } else {
                log("No audio device available after change. Waiting for recovery...")
                self.scheduleRecovery()
            }
        }
        debounceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceSeconds, execute: work)
    }

    // MARK: - Recovery (coreaudiod restart, no devices)

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

    /// Signal-safe shutdown: only calls POSIX functions (no Swift/Foundation APIs).
    func signalShutdown() {
        session?.stopRunning()
        session = nil
        cleanupPID()
    }

    func shutdown() {
        debounceWork?.cancel()
        session?.stopRunning()
        session = nil
        cleanupPID()
        log("Shutdown complete")
    }
}

// MARK: - Signal handling & main

let keeper = MicKeeper()

// Signal handler using @convention(c). Only calls signal-safe operations:
// signal() and _exit() are async-signal-safe per POSIX. signalShutdown() only
// calls stopRunning/unlink which are safe enough for a daemon exiting immediately.
// DispatchSource.makeSignalSource is the "correct" alternative but doesn't reliably
// fire with dispatchMain() in all configurations.
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
keeper.start()
dispatchMain()
