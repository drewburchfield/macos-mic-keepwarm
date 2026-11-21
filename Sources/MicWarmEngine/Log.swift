import Foundation

// MARK: - Logging

// ISO8601DateFormatter is thread-safe, unlike DateFormatter.
// log() is called from multiple queues.
public let logDateFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withTime, .withColonSeparatorInTime, .withFractionalSeconds]
    // autoupdatingCurrent follows a time zone change while the process runs. `.current` froze
    // the zone at launch, so a daemon started before travel logged hours off from the clock.
    f.timeZone = .autoupdatingCurrent
    return f
}()

/// Where log lines go. The CLI writes them to stdout (launchd sends that to mic-warm.log);
/// the app writes them to its own file. Set once at startup, before the engine starts.
public enum EngineLog {
    nonisolated(unsafe) public static var sink: (String) -> Void = { line in
        print(line)
        fflush(stdout)
    }
}

public func log(_ msg: String) {
    EngineLog.sink("[\(logDateFormatter.string(from: Date()))] \(msg)")
}
