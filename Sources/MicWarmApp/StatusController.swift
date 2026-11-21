import AppKit
import MicWarmCore
import MicWarmEngine

/// Owns the menu-bar item: the Fire circle glyph for the current state and the native menu.
/// Hold Option while opening the menu for the diagnostic items (Preview State, logs, switching
/// back to the command-line daemon).
final class StatusController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let model: AppModel

    /// Ring spin: one 60° stone-to-stone step in 10 frames at 15 fps, a full turn every 4 s.
    private static let spinFrameCount = 10
    private static let spinInterval: TimeInterval = 1.0 / 15.0

    private lazy var glyphs: [WarmState: NSImage] = Dictionary(
        uniqueKeysWithValues: WarmState.allCases.map { ($0, FireCircleGlyph.image(for: $0)) })
    private lazy var spinFrames = FireCircleGlyph.spinFrames(for: .recovering, count: Self.spinFrameCount)
    private var spinTimer: Timer?
    private var spinIndex = 0

    /// A glyph state picked from Preview State, shown instead of the live one until cleared.
    private var preview: WarmState?

    init(model: AppModel, preview: WarmState? = nil) {
        self.model = model
        self.preview = preview
        super.init()
        menu.autoenablesItems = false
        menu.delegate = self
        item.menu = menu
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(reduceMotionChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        model.onChange = { [weak self] in self?.render() }
        render()
    }

    // MARK: - State

    /// The glyph for what the model reports.
    private var liveGlyphState: WarmState {
        switch model.display {
        case .live(.starting), .live(.warm), .standby, .switching: return .warm
        case .live(.recovering), .live(.noDevice): return .recovering
        case .live(.paused): return .paused
        case .needsAccess: return .needsAccess
        }
    }

    private var glyphState: WarmState { preview ?? liveGlyphState }

    // MARK: - Glyph

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private func render() {
        let state = glyphState
        item.button?.image = glyphs[state]
        // In standby the CLI holds the mic; a dimmed glyph says the app is not the one doing it.
        item.button?.appearsDisabled = preview == nil && (model.display == .standby || model.display == .switching)
        item.button?.setAccessibilityLabel(state.accessibilityLabel)
        updateSpin()
        rebuildMenu()
    }

    private func updateSpin() {
        let shouldSpin = glyphState.isAnimated && !reduceMotion
        if shouldSpin, spinTimer == nil {
            spinIndex = 0
            let timer = Timer(timeInterval: Self.spinInterval, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.spinIndex = (self.spinIndex + 1) % self.spinFrames.count
                self.item.button?.image = self.spinFrames[self.spinIndex]
            }
            // .common keeps the ring turning while the menu is open.
            RunLoop.main.add(timer, forMode: .common)
            spinTimer = timer
        } else if !shouldSpin, let timer = spinTimer {
            timer.invalidate()
            spinTimer = nil
            item.button?.image = glyphs[glyphState]
        }
    }

    @objc private func reduceMotionChanged() { updateSpin() }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) { rebuildMenu() }

    private func rebuildMenu() {
        menu.removeAllItems()
        let showDiagnostics = NSEvent.modifierFlags.contains(.option) || preview != nil
        let device = model.device ?? "your mic"

        let (title, detail, dot) = headline(device: device)
        menu.addItem(headerItem(title, dot: dot))
        menu.addItem(detailItem(model.switchError ?? detail))

        switch model.display {
        case .standby:
            menu.addItem(.separator())
            menu.addItem(action("Switch to Mic Warm App", #selector(switchToApp)))
        case .needsAccess:
            menu.addItem(.separator())
            menu.addItem(action("Open Privacy Settings…", #selector(openPrivacySettings)))
        case .live:
            menu.addItem(.separator())
            menu.addItem(action(model.isPaused ? "Resume" : "Pause", #selector(togglePause)))
        case .switching:
            break
        }

        menu.addItem(.separator())
        let login = action("Open at Login", #selector(toggleOpenAtLogin))
        login.state = model.opensAtLogin ? .on : .off
        menu.addItem(login)
        menu.addItem(action("Sound Settings…", #selector(openSoundSettings)))

        if showDiagnostics {
            menu.addItem(.separator())
            menu.addItem(previewMenu())
            menu.addItem(action("Show Logs in Finder", #selector(showLogs)))
            if model.canSwitchBack {
                menu.addItem(action("Switch Back to Command-Line mic-warm", #selector(switchBack)))
            }
        }

        menu.addItem(.separator())
        menu.addItem(action("About Mic Warm", #selector(showAbout)))
        let quit = NSMenuItem(title: "Quit Mic Warm", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    private func headline(device: String) -> (String, String, NSColor) {
        if let preview {
            return ("Previewing \(preview.previewTitle)", "Pick Live in Preview State to go back", .systemPurple)
        }
        switch model.display {
        case .live(.starting), .live(.warm):
            return ("Keeping \(device) warm", "Push-to-talk starts instantly", .systemGreen)
        case .live(.recovering):
            return ("Recovering \(device)", "The signal dropped, so Mic Warm is restarting the mic", .systemOrange)
        case .live(.noDevice):
            return ("Waiting for a microphone", "Mic Warm retries every few seconds", .systemOrange)
        case .live(.paused):
            return ("Paused", "The mic is released, so push-to-talk may lag", .systemGray)
        case .needsAccess:
            return ("Needs microphone access", "Allow Mic Warm in Privacy & Security", .systemRed)
        case .standby:
            return ("Command-line mic-warm has the mic", "Mic Warm is standing by", .systemGray)
        case .switching:
            return ("Switching…", "Handing the mic over", .systemGray)
        }
    }

    private func headerItem(_ title: String, dot: NSColor) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.menuFont(ofSize: 0).bold,
            .foregroundColor: NSColor.labelColor,
        ])
        let config = NSImage.SymbolConfiguration(pointSize: 7, weight: .regular)
            .applying(.init(paletteColors: [dot]))
        item.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        item.isEnabled = false
        return item
    }

    private func detailItem(_ text: String) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        item.isEnabled = false
        return item
    }

    private func action(_ title: String, _ selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        return item
    }

    /// Diagnostic: shows any state's glyph without changing what the engine does.
    private func previewMenu() -> NSMenuItem {
        let sub = NSMenu()
        let live = NSMenuItem(title: "Live", action: #selector(pickPreviewState(_:)), keyEquivalent: "")
        live.target = self
        live.state = preview == nil ? .on : .off
        sub.addItem(live)
        sub.addItem(.separator())
        for s in WarmState.allCases {
            let item = NSMenuItem(title: s.previewTitle, action: #selector(pickPreviewState(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = s.rawValue
            item.state = s == preview ? .on : .off
            item.image = glyphs[s]
            sub.addItem(item)
        }
        let parent = NSMenuItem(title: "Preview State", action: nil, keyEquivalent: "")
        parent.submenu = sub
        return parent
    }

    // MARK: - Actions

    @objc private func pickPreviewState(_ sender: NSMenuItem) {
        preview = (sender.representedObject as? String).flatMap(WarmState.init(rawValue:))
        render()
    }

    @objc private func togglePause() { model.togglePause() }
    @objc private func switchToApp() { model.switchToApp() }
    @objc private func switchBack() { model.switchBackToCLI() }
    @objc private func toggleOpenAtLogin() { model.setOpenAtLogin(!model.opensAtLogin) }

    @objc private func showLogs() {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: AppLog.path)])
    }

    @objc private func openSoundSettings() {
        open("x-apple.systempreferences:com.apple.preference.sound?input")
    }

    @objc private func openPrivacySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    private func open(_ url: String) {
        if let u = URL(string: url) { NSWorkspace.shared.open(u) }
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }
}

private extension WarmState {
    var previewTitle: String {
        switch self {
        case .warm: return "Warm"
        case .recovering: return "Recovering"
        case .paused: return "Paused"
        case .needsAccess: return "Needs Access"
        }
    }
}

private extension NSFont {
    var bold: NSFont { NSFontManager.shared.convert(self, toHaveTrait: .boldFontMask) }
}
