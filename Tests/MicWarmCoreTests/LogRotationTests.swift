import Darwin
import Foundation
import MicWarmCore
import XCTest

final class LogRotationTests: XCTestCase {
    var dir: String!
    var path: String { (dir as NSString).appendingPathComponent("test.log") }

    override func setUpWithError() throws {
        dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("mic-warm-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: dir)
    }

    func contents(_ p: String) -> String? { try? String(contentsOfFile: p, encoding: .utf8) }

    func write(_ text: String, to fd: Int32) {
        _ = text.withCString { Darwin.write(fd, $0, strlen($0)) }
    }

    func testUnderLimitIsLeftAlone() throws {
        try "small".write(toFile: path, atomically: false, encoding: .utf8)
        XCTAssertEqual(LogRotation.rotateIfNeeded(path, limit: 100), .notNeeded)
        XCTAssertEqual(contents(path), "small")
        XCTAssertFalse(FileManager.default.fileExists(atPath: path + ".1"))
    }

    func testOverLimitMovesToDotOneAndReplacesOldDotOne() throws {
        try "older".write(toFile: path + ".1", atomically: false, encoding: .utf8)
        try String(repeating: "x", count: 200).write(toFile: path, atomically: false, encoding: .utf8)
        XCTAssertEqual(LogRotation.rotateIfNeeded(path, limit: 100), .rotated)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        XCTAssertEqual(contents(path + ".1")?.count, 200)
    }

    func testRotatesWhenTheNextAppendWouldPassTheLimit() throws {
        try String(repeating: "x", count: 60).write(toFile: path, atomically: false, encoding: .utf8)
        XCTAssertEqual(LogRotation.rotateIfNeeded(path, limit: 100, incoming: 40), .notNeeded)
        XCTAssertEqual(LogRotation.rotateIfNeeded(path, limit: 100, incoming: 41), .rotated)
    }

    func testMissingFileIsNotAnError() {
        XCTAssertEqual(LogRotation.rotateIfNeeded(path, limit: 100), .notNeeded)
    }

    func testInheritedFdIsRepointedAtAFreshFile() {
        let fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        write(String(repeating: "a", count: 200), to: fd)

        XCTAssertEqual(LogRotation.rotateInheritedLog(path, fds: [fd], limit: 100), .rotated)
        write("after rotation\n", to: fd)

        XCTAssertEqual(contents(path + ".1")?.count, 200)
        XCTAssertEqual(contents(path), "after rotation\n")
    }

    func testInheritedRotationSkipsFdsThatAreNotTheLogFile() {
        // A terminal run: stdout is a pipe or tty, not the log file.
        var pipeFds: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&pipeFds), 0)
        defer { close(pipeFds[0]); close(pipeFds[1]) }
        FileManager.default.createFile(atPath: path, contents: Data(repeating: 0x61, count: 200))

        var before = stat()
        XCTAssertEqual(fstat(pipeFds[1], &before), 0)

        XCTAssertEqual(LogRotation.rotateInheritedLog(path, fds: [pipeFds[1]], limit: 100), .notNeeded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path + ".1"))

        // The pipe is still open and still the same pipe.
        var after = stat()
        XCTAssertEqual(fstat(pipeFds[1], &after), 0)
        XCTAssertEqual(after.st_ino, before.st_ino)
        write("still a pipe", to: pipeFds[1])
        var buf = [UInt8](repeating: 0, count: 32)
        XCTAssertEqual(read(pipeFds[0], &buf, buf.count), 12)
    }

    func testLaunchdShapeRepointsBothLogFdsAndLeavesThePipe() {
        // launchd: stdout and stderr both open on the log file; a third fd is unrelated.
        let out = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        let err = open(path, O_WRONLY | O_APPEND)
        var pipeFds: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&pipeFds), 0)
        defer { close(out); close(err); close(pipeFds[0]); close(pipeFds[1]) }
        write(String(repeating: "a", count: 200), to: out)

        XCTAssertEqual(LogRotation.rotateInheritedLog(path, fds: [out, err, pipeFds[1]], limit: 100), .rotated)
        write("out\n", to: out)
        write("err\n", to: err)
        write("pipe", to: pipeFds[1])

        XCTAssertEqual(contents(path), "out\nerr\n")
        XCTAssertEqual(contents(path + ".1")?.count, 200)
        var buf = [UInt8](repeating: 0, count: 8)
        XCTAssertEqual(read(pipeFds[0], &buf, buf.count), 4)
    }

    func testFailedOpenLeavesTheLogInPlaceSoRotationCanRetry() throws {
        let fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        defer { close(fd) }
        write(String(repeating: "a", count: 200), to: fd)
        // A directory where the staging file goes makes the open fail.
        try FileManager.default.createDirectory(atPath: path + ".new", withIntermediateDirectories: false)

        guard case .failed = LogRotation.rotateInheritedLog(path, fds: [fd], limit: 100) else {
            return XCTFail("expected failure")
        }
        XCTAssertEqual(contents(path)?.count, 200)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path + ".1"))

        // Once the obstruction clears, the next tick rotates.
        try FileManager.default.removeItem(atPath: path + ".new")
        XCTAssertEqual(LogRotation.rotateInheritedLog(path, fds: [fd], limit: 100), .rotated)
        write("after\n", to: fd)
        XCTAssertEqual(contents(path), "after\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: path + ".new"))
    }

    func testInheritedRotationUnderLimitIsLeftAlone() {
        let fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        defer { close(fd) }
        write("tiny", to: fd)
        XCTAssertEqual(LogRotation.rotateInheritedLog(path, fds: [fd], limit: 100), .notNeeded)
        XCTAssertEqual(contents(path), "tiny")
    }
}
