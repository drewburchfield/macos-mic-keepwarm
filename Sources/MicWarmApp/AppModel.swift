import AppKit
import AVFoundation
import MicWarmCore
import MicWarmEngine
import ServiceManagement

/// What the menu-bar item shows.
enum Display: Equatable {
    /// The app holds the mic; the engine's status.
    case live(KeeperStatus)
    /// The app holds the lock but lacks microphone permission.
    case needsAccess
    /// Another mic-warm (the command-line daemon) holds the mic. The app waits.
    case standby
    /// Handing the mic between the CLI and the app.
    case switching
}

/// Decides who holds the mic, runs the engine when the app does, and keeps the prefs.
final class AppModel {
    private let keeper = MicKeeper()
    private var keeperStarted = false
    private var lock: InstanceLock?
    private var pollTimer: Timer?
    private let defaults = UserDefaults.standard

    private(set) var display: Display = .switching {
        didSet {
            guard display != oldValue else { return }
            log("[app] Status: \(display)")
            onChange?()
        }
    }
    private(set) var device: String?
    /// The last error from a switch, shown under the header until the next switch.
    private(set) var switchError: String?
    var onChange: (() -> Void)?

    static let lockPath = ProcessInfo.processInfo.environment["MIC_WARM_LOCK"]
        ?? (NSHomeDirectory() as NSString).appendingPathComponent("Library/Application Support/mic-warm/mic-warm.lock")

    // MARK: Prefs (versioned so later per-device rules can migrate)

    private enum Key {
        static let version = "prefsVersion"
        static let paused = "paused"
        static let loginItemDefaulted = "loginItemDefaulted"
    }

    private static let prefsVersion = 1

    var isPaused: Bool { defaults.bool(forKey: Key.paused) }

    // MARK: Launch

    func launch() {
        if defaults.integer(forKey: Key.version) < Self.prefsVersion {
            defaults.set(Self.prefsVersion, forKey: Key.version)
        }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        log("Mic Warm app starting (PID: \(getpid()), version: \(version))")
        keeper.onStatusChange = { [weak self] status, device in
            guard let self, self.lock != nil else { return }
            self.device = device
            if case .live = self.display { self.display = .live(status) } else { self.onChange?() }
        }
        decideOwner()
    }

    /// The CLI keeps the mic while its LaunchAgent is loaded; otherwise the app takes the lock.
    private func decideOwner() {
        DispatchQueue.global(qos: .utility).async {
            let agentLoaded = LegacyAgent.isLoaded()
            DispatchQueue.main.async { self.ownerDecided(agentLoaded: agentLoaded) }
        }
    }

    private func ownerDecided(agentLoaded: Bool) {
        guard lock == nil else { return }
        if agentLoaded {
            enterStandby(reason: "the command-line mic-warm LaunchAgent is loaded")
            return
        }
        let candidate = InstanceLock(path: Self.lockPath)
        switch candidate.tryAcquire() {
        case .acquired:
            lock = candidate
            becomeOwner()
        case .held(let owner):
            enterStandby(reason: "the instance lock is held by \(owner.map { "PID \($0)" } ?? "another process")")
        case .failed(let err):
            // Same as the CLI: run without the lock rather than not at all.
            log("Warning: instance lock \(Self.lockPath) unavailable (\(err)); continuing without it")
            lock = candidate
            becomeOwner()
        }
    }

    private func enterStandby(reason: String) {
        if display != .standby { log("Standing by: \(reason)") }
        display = .standby
        schedulePoll(every: 10) { [weak self] in self?.decideOwner() }
    }

    private func becomeOwner() {
        pollTimer?.invalidate()
        pollTimer = nil
        log("Holding the instance lock; the app keeps the mic warm")
        // Default Open at Login on once, for the installed copy only (not a build-folder run).
        if Bundle.main.bundlePath.hasPrefix("/Applications/"), !defaults.bool(forKey: Key.loginItemDefaulted) {
            defaults.set(true, forKey: Key.loginItemDefaulted)
            setOpenAtLogin(true)
        }
        startWhenAuthorized()
    }

    private func startWhenAuthorized() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            pollTimer?.invalidate()
            pollTimer = nil
            startKeeper()
        case .notDetermined:
            display = .needsAccess
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                DispatchQueue.main.async { self.startWhenAuthorized() }
            }
        default:
            if display != .needsAccess { log("Microphone access denied; waiting for it in Privacy & Security") }
            display = .needsAccess
            schedulePoll(every: 3) { [weak self] in self?.startWhenAuthorized() }
        }
    }

    private func startKeeper() {
        if keeperStarted {
            if !isPaused { keeper.resume() }
        } else {
            keeperStarted = true
            keeper.start(paused: isPaused)
        }
        display = .live(isPaused ? .paused : keeper.currentStatus.status)
    }

    private func schedulePoll(every seconds: TimeInterval, _ body: @escaping () -> Void) {
        pollTimer?.invalidate()
        let timer = Timer(timeInterval: seconds, repeats: false) { _ in body() }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    // MARK: Actions

    func togglePause() {
        guard case .live = display else { return }
        let pause = !isPaused
        defaults.set(pause, forKey: Key.paused)
        if pause { keeper.pause() } else { keeper.resume() }
    }

    /// Stops the CLI daemon for good and takes over the mic.
    func switchToApp() {
        guard display == .standby else { return }
        log("Switching from the command-line mic-warm to the app")
        switchError = nil
        display = .switching
        DispatchQueue.global(qos: .userInitiated).async {
            let err = LegacyAgent.isInstalled ? LegacyAgent.disableAndStop() : nil
            DispatchQueue.main.async {
                if let err {
                    log("Switch: \(err)")
                    self.switchError = "Couldn't stop the command-line mic-warm"
                }
                self.acquireAfterSwitch(attemptsLeft: 40)
            }
        }
    }

    // The CLI releases the lock as it exits, a moment after bootout returns.
    private func acquireAfterSwitch(attemptsLeft: Int) {
        let candidate = InstanceLock(path: Self.lockPath)
        if case .acquired = candidate.tryAcquire() {
            lock = candidate
            setOpenAtLogin(true)
            becomeOwner()
        } else if attemptsLeft > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                self.acquireAfterSwitch(attemptsLeft: attemptsLeft - 1)
            }
        } else {
            log("Switch: the instance lock is still held after 10s")
            switchError = "The mic is still held by another mic-warm"
            enterStandby(reason: "the instance lock is still held")
        }
    }

    var canSwitchBack: Bool { lock != nil && LegacyAgent.isInstalled }

    /// Releases the mic, turns the CLI daemon back on, and quits.
    func switchBackToCLI() {
        guard canSwitchBack else { return }
        log("Switching back to the command-line mic-warm")
        display = .switching
        setOpenAtLogin(false)
        keeper.pause { [self] in
            lock = nil  // closing the descriptor releases the lock for the CLI
            DispatchQueue.global(qos: .userInitiated).async {
                if let err = LegacyAgent.enableAndStart() { log("Switch back: \(err)") }
                DispatchQueue.main.async { NSApp.terminate(nil) }
            }
        }
    }

    // MARK: Open at Login

    var opensAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    func setOpenAtLogin(_ on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            log("Open at Login \(on ? "on" : "off")")
        } catch {
            log("Open at Login \(on ? "register" : "unregister") failed: \(error.localizedDescription)")
        }
        onChange?()
    }
}
