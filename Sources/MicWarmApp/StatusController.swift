import AppKit
import AVFoundation
import MicWarmCore

/// Owns the menu-bar item: the Fire circle glyph for the current state and the native menu.
///
/// The capture engine is not wired in yet, so the state comes from the Preview State submenu
/// (or `--state` at launch). When the engine moves into the app it sets `state` instead.
final class StatusController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()

    /// Ring spin: one 60° stone-to-stone step in 10 frames at 15 fps, a full turn every 4 s.
    private static let spinFrameCount = 10
    private static let spinInterval: TimeInterval = 1.0 / 15.0

    private lazy var glyphs: [WarmState: NSImage] = Dictionary(
        uniqueKeysWithValues: WarmState.allCases.map { ($0, FireCircleGlyph.image(for: $0)) })
    private lazy var spinFrames = FireCircleGlyph.spinFrames(for: .recovering, count: Self.spinFrameCount)
    private var spinTimer: Timer?
    private var spinIndex = 0

    var state: WarmState {
        didSet { if state != oldValue { render() } }
    }

    init(state: WarmState) {
        self.state = state
        super.init()
        menu.autoenablesItems = false
        menu.delegate = self
        item.menu = menu
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(reduceMotionChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        render()
    }

    // MARK: - Glyph

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private func render() {
        item.button?.image = glyphs[state]
        item.button?.setAccessibilityLabel(state.accessibilityLabel)
        updateSpin()
        rebuildMenu()
    }

    private func updateSpin() {
        let shouldSpin = state.isAnimated && !reduceMotion
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
            item.button?.image = glyphs[state]
        }
    }

    @objc private func reduceMotionChanged() { updateSpin() }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) { rebuildMenu() }

    private func rebuildMenu() {
        menu.removeAllItems()
        let device = AVCaptureDevice.default(for: .audio)?.localizedName ?? "the default microphone"

        let (title, detail, dot): (String, String, NSColor) = {
            switch state {
            case .warm: return ("Warming \(device)", "Signal OK", .systemGreen)
            case .recovering: return ("Recovering \(device)", "Signal went flat, restarting the mic", .systemOrange)
            case .paused: return ("Paused", "The mic is released", .systemGray)
            case .needsAccess: return ("Needs microphone access", "Allow Mic Warm in Privacy & Security", .systemRed)
            }
        }()
        menu.addItem(headerItem(title, dot: dot))
        menu.addItem(detailItem(detail))

        if state == .needsAccess {
            menu.addItem(.separator())
            menu.addItem(action("Open Privacy Settings…", #selector(openPrivacySettings)))
        }

        menu.addItem(.separator())
        menu.addItem(previewMenu())
        menu.addItem(action("Open Sound Settings…", #selector(openSoundSettings)))

        menu.addItem(.separator())
        menu.addItem(action("About Mic Warm", #selector(showAbout)))
        let quit = NSMenuItem(title: "Quit Mic Warm", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
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

    /// Temporary: drives the glyph by hand until the capture engine moves into the app.
    private func previewMenu() -> NSMenuItem {
        let sub = NSMenu()
        for s in WarmState.allCases {
            let item = NSMenuItem(title: s.previewTitle, action: #selector(pickPreviewState(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = s.rawValue
            item.state = s == state ? .on : .off
            item.image = glyphs[s]
            sub.addItem(item)
        }
        let parent = NSMenuItem(title: "Preview State", action: nil, keyEquivalent: "")
        parent.submenu = sub
        return parent
    }

    @objc private func pickPreviewState(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let s = WarmState(rawValue: raw) else { return }
        state = s
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
