import Foundation
import MicWarmCore
import MicWarmEngine

/// The app's log: ~/Library/Logs/mic-warm/app.log, next to the CLI's mic-warm.log and the
/// shared bt.log. Capped like the CLI's logs (current file plus one `.1`).
enum AppLog {
    static let path = (btLogDir as NSString).appendingPathComponent("app.log")
    private static let queue = DispatchQueue(label: "com.micwarm.app.log", qos: .utility)
    nonisolated(unsafe) private static var handle: FileHandle?

    /// Points the engine's log at the file. Call once at launch.
    static func install() {
        EngineLog.sink = { line in
            queue.async { write(line + "\n") }
        }
    }

    private static func write(_ text: String) {
        let data = Data(text.utf8)
        if case .rotated = LogRotation.rotateIfNeeded(path, incoming: off_t(data.count)) {
            try? handle?.close()
            handle = nil
        }
        if handle == nil {
            let fm = FileManager.default
            try? fm.createDirectory(atPath: btLogDir, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
            if !fm.fileExists(atPath: path) {
                fm.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: path))
            _ = try? handle?.seekToEnd()
        }
        // The throwing API: the legacy write(_:) raises an uncatchable exception on ENOSPC.
        do {
            try handle?.write(contentsOf: data)
        } catch {
            try? handle?.close()
            handle = nil
        }
    }
}
