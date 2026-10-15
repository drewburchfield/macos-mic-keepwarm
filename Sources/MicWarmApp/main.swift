import AppKit
import MicWarmCore

// Mic Warm menu-bar app. Runs as an accessory (no Dock icon, LSUIElement in Info.plist).
//
// Arguments:
//   --state <warm|recovering|paused|needs-access>   start in a preview state
//   --render-glyphs <dir>                            write each state's glyph as PNG (1x, 2x) and exit

func argument(after flag: String) -> String? {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
}

func renderGlyphs(to dir: String) -> Int32 {
    let url = URL(fileURLWithPath: dir, isDirectory: true)
    do {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for state in WarmState.allCases {
            for scale in [1, 2] {
                let px = Int(FireCircleGlyph.size.width) * scale
                guard let rep = NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                    bytesPerRow: 0, bitsPerPixel: 0) else { return 1 }
                rep.size = FireCircleGlyph.size
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                FireCircleGlyph.image(for: state).draw(in: NSRect(origin: .zero, size: FireCircleGlyph.size))
                NSGraphicsContext.restoreGraphicsState()
                let suffix = scale == 1 ? "" : "@\(scale)x"
                try rep.representation(using: .png, properties: [:])?
                    .write(to: url.appendingPathComponent("\(state.rawValue)\(suffix).png"))
            }
        }
        return 0
    } catch {
        FileHandle.standardError.write(Data("render-glyphs: \(error)\n".utf8))
        return 1
    }
}

if let dir = argument(after: "--render-glyphs") {
    exit(renderGlyphs(to: dir))
}

let initialState: WarmState
if let raw = argument(after: "--state") {
    guard let s = WarmState(rawValue: raw) else {
        let names = WarmState.allCases.map(\.rawValue).joined(separator: ", ")
        FileHandle.standardError.write(Data("Unknown state \"\(raw)\". Use one of: \(names)\n".utf8))
        exit(2)
    }
    initialState = s
} else {
    initialState = .warm
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = StatusController(state: initialState)
app.run()
