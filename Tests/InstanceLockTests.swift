import Darwin
import Foundation

struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw TestFailure(description: message) }
}

func expectRejected(_ url: URL) throws {
    do {
        _ = try InstanceLock(at: url)
    } catch is InstanceLock.Failure {
        return
    }
    throw TestFailure(description: "Unsafe lock file was accepted: \(url.path)")
}

func expectBusy(_ url: URL) throws {
    do {
        _ = try InstanceLock(at: url)
    } catch InstanceLock.Failure.alreadyRunning {
        return
    }
    throw TestFailure(description: "Second instance acquired a held lock")
}

@main
struct InstanceLockTests {
    static func main() throws {
        if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--print-lock-path" {
            print(try InstanceLock.defaultURL().path)
            return
        }
        // A separate process exercises kernel lock contention and process-exit
        // release without ever opening a microphone or touching the live lock.
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--hold-lock" {
            let lock = try InstanceLock(at: URL(fileURLWithPath: CommandLine.arguments[2]))
            print("READY")
            fflush(stdout)
            withExtendedLifetime(lock) { while true { pause() } }
            return
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mic-warm-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("instance.lock")

        func run(_ name: String, _ body: () throws -> Void) throws {
            try body()
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            print("PASS: \(name)")
        }

        try run("launch environments resolve the same default lock path") {
            let expected = try InstanceLock.defaultURL().path + "\n"
            let child = Process()
            child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            child.arguments = ["--print-lock-path"]
            var environment = ProcessInfo.processInfo.environment
            environment["TMPDIR"] = directory.path
            child.environment = environment
            let output = Pipe()
            child.standardOutput = output
            try child.run()
            let result = output.fileHandleForReading.readDataToEndOfFile()
            child.waitUntilExit()
            try expect(child.terminationStatus == 0, "Child could not resolve default lock")
            try expect(String(data: result, encoding: .utf8) == expected, "TMPDIR changed the lock path")
        }

        try run("duplicate instance is rejected") {
            let first = try InstanceLock(at: url)
            try withExtendedLifetime(first) { try expectBusy(url) }
        }

        try run("release permits reuse of the same lock file") {
            var first: InstanceLock? = try InstanceLock(at: url)
            let before = try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber
            try expect(first != nil, "First lock missing")
            first = nil
            let second = try InstanceLock(at: url)
            let after = try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber
            try expect(before != nil && before == after, "Lock file was replaced")
            withExtendedLifetime(second) {}
        }

        try run("stale, zero, negative, and invalid PID contents are ignored") {
            for contents in ["0", "-1", "-123", "99999", "not a PID"] {
                try contents.write(to: url, atomically: false, encoding: .utf8)
                let lock = try InstanceLock(at: url)
                try expect(String(contentsOf: url, encoding: .utf8) == contents, "Contents changed")
                withExtendedLifetime(lock) {}
            }
        }

        try run("unrelated live process is not signaled") {
            let unrelated = Process()
            unrelated.executableURL = URL(fileURLWithPath: "/bin/sleep")
            unrelated.arguments = ["30"]
            try unrelated.run()
            defer {
                if unrelated.isRunning { unrelated.terminate() }
                unrelated.waitUntilExit()
            }
            let contents = String(unrelated.processIdentifier)
            try contents.write(to: url, atomically: false, encoding: .utf8)
            let lock = try InstanceLock(at: url)
            try expect(unrelated.isRunning, "Unrelated process was stopped")
            try expect(String(contentsOf: url, encoding: .utf8) == contents, "Contents changed")
            withExtendedLifetime(lock) {}
        }

        let target = directory.appendingPathComponent("unrelated.txt")
        try "keep me".write(to: target, atomically: false, encoding: .utf8)
        try run("symlink is rejected without changing its target") {
            try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
            try expectRejected(url)
            try expect(String(contentsOf: target, encoding: .utf8) == "keep me", "Target changed")
        }
        try run("hard link is rejected without changing its target") {
            try FileManager.default.linkItem(at: target, to: url)
            try expectRejected(url)
            try expect(String(contentsOf: target, encoding: .utf8) == "keep me", "Target changed")
        }
        try run("directory is rejected") {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            try expectRejected(url)
        }
        try run("new lock file has private permissions") {
            let lock = try InstanceLock(at: url)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            try expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "Lock is not private")
            withExtendedLifetime(lock) {}
        }

        for signal in [SIGTERM, SIGKILL] {
            try run("cross-process exclusion and release on signal \(signal)") {
                let child = Process()
                child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
                child.arguments = ["--hold-lock", url.path]
                let output = Pipe()
                child.standardOutput = output
                try child.run()
                defer {
                    if child.isRunning { child.terminate() }
                    child.waitUntilExit()
                }
                let ready = output.fileHandleForReading.readData(ofLength: 6)
                try expect(String(data: ready, encoding: .utf8) == "READY\n", "Child failed to lock")
                try expectBusy(url)
                try expect(kill(child.processIdentifier, signal) == 0, "Could not stop child")
                child.waitUntilExit()
                let next = try InstanceLock(at: url)
                withExtendedLifetime(next) {}
            }
        }
        print("All 11 instance-lock regressions passed")
    }
}
