import Foundation

/// The command-line mic-warm LaunchAgent that install.sh sets up. The app and the CLI share
/// one instance lock, so only one of them holds the mic. Switching moves ownership in one
/// step: the app disables the agent (so it stays off across logins) and boots it out.
/// Switching back re-enables and bootstraps it.
enum LegacyAgent {
    // MIC_WARM_AGENT_LABEL lets a test run the app as owner beside a loaded agent.
    static let label = ProcessInfo.processInfo.environment["MIC_WARM_AGENT_LABEL"] ?? "com.user.keep-mic-warm"
    static let plistPath = (NSHomeDirectory() as NSString)
        .appendingPathComponent("Library/LaunchAgents/\(label).plist")

    private static var target: String { "gui/\(getuid())/\(label)" }

    /// install.sh put the agent's plist in place.
    static var isInstalled: Bool { FileManager.default.fileExists(atPath: plistPath) }

    /// launchd has the agent loaded. Blocks for a moment; call off the main thread.
    static func isLoaded() -> Bool {
        launchctl(["print", target]).status == 0
    }

    /// Stops the CLI and keeps it from starting at the next login.
    @discardableResult
    static func disableAndStop() -> String? {
        var errors: [String] = []
        let disable = launchctl(["disable", target])
        if disable.status != 0 { errors.append("disable: \(disable.output)") }
        let bootout = launchctl(["bootout", target])
        // 3 (ESRCH) and 113 mean it was not loaded, which is the goal anyway.
        if bootout.status != 0 && bootout.status != 3 && bootout.status != 113 {
            errors.append("bootout (\(bootout.status)): \(bootout.output)")
        }
        return errors.isEmpty ? nil : errors.joined(separator: "; ")
    }

    /// Re-enables the CLI agent and starts it now.
    @discardableResult
    static func enableAndStart() -> String? {
        var errors: [String] = []
        let enable = launchctl(["enable", target])
        if enable.status != 0 { errors.append("enable: \(enable.output)") }
        let boot = launchctl(["bootstrap", "gui/\(getuid())", plistPath])
        // 5 (EIO) / 37 come back when it is already loaded.
        if boot.status != 0 && boot.status != 5 && boot.status != 37 {
            errors.append("bootstrap (\(boot.status)): \(boot.output)")
        }
        return errors.isEmpty ? nil : errors.joined(separator: "; ")
    }

    private static func launchctl(_ args: [String]) -> (status: Int32, output: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        do {
            try proc.run()
        } catch {
            return (-1, error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return (proc.terminationStatus, String(text.prefix(300)))
    }
}
