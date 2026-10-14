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
        XCTAssertFalse(LogRotation.rotateIfNeeded(path, limit: 100))
        XCTAssertEqual(contents(path), "small")
        XCTAssertFalse(FileManager.default.fileExists(atPath: path + ".1"))
    }

    func testOverLimitMovesToDotOneAndReplacesOldDotOne() throws {
        try "older".write(toFile: path + ".1", atomically: false, encoding: .utf8)
        try String(repeating: "x", count: 200).write(toFile: path, atomically: false, encoding: .utf8)
        XCTAssertTrue(LogRotation.rotateIfNeeded(path, limit: 100))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        XCTAssertEqual(contents(path + ".1")?.count, 200)
    }

    func testMissingFileIsNotAnError() {
        XCTAssertFalse(LogRotation.rotateIfNeeded(path, limit: 100))
    }

    func testInheritedFdIsRepointedAtAFreshFile() {
        let fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        write(String(repeating: "a", count: 200), to: fd)

        XCTAssertTrue(LogRotation.rotateInheritedLog(path, fds: [fd], limit: 100))
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

        XCTAssertFalse(LogRotation.rotateInheritedLog(path, fds: [pipeFds[1]], limit: 100))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path + ".1"))
    }

    func testInheritedRotationUnderLimitIsLeftAlone() {
        let fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        defer { close(fd) }
        write("tiny", to: fd)
        XCTAssertFalse(LogRotation.rotateInheritedLog(path, fds: [fd], limit: 100))
        XCTAssertEqual(contents(path), "tiny")
    }
}
