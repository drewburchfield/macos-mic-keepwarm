import Darwin
import Foundation
import MicWarmCore
import XCTest

final class InstanceLockTests: XCTestCase {
    var dir: String!
    var path: String { (dir as NSString).appendingPathComponent("sub/mic-warm.lock") }

    override func setUpWithError() throws {
        dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("mic-warm-lock-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: dir)
    }

    func testAcquireWritesOurPID() throws {
        let lock = InstanceLock(path: path)
        XCTAssertEqual(lock.tryAcquire(), .acquired)
        let text = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertEqual(text, "\(getpid())\n")
    }

    func testSecondHolderSeesTheOwnerUntilTheFirstReleases() {
        var first: InstanceLock? = InstanceLock(path: path)
        XCTAssertEqual(first?.tryAcquire(), .acquired)

        let second = InstanceLock(path: path)
        XCTAssertEqual(second.tryAcquire(), .held(owner: getpid()))

        first = nil  // closing the fd releases the lock
        XCTAssertEqual(second.tryAcquire(), .acquired)
    }

    func testStalePIDInAnUnlockedFileIsIgnored() throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try "1\n".write(toFile: path, atomically: false, encoding: .utf8)
        let lock = InstanceLock(path: path)
        XCTAssertEqual(lock.tryAcquire(), .acquired)
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "\(getpid())\n")
    }

    func testRefusesASymlink() throws {
        let sub = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: sub, withIntermediateDirectories: true)
        let target = (dir as NSString).appendingPathComponent("victim")
        try "keep".write(toFile: target, atomically: false, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: target)

        guard case .failed = InstanceLock(path: path).tryAcquire() else { return XCTFail("followed symlink") }
        XCTAssertEqual(try String(contentsOfFile: target, encoding: .utf8), "keep")
    }

    func testOnlyNamedExecutablesOwnedByUsCount() throws {
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["30"]
        try sleeper.run()
        defer { sleeper.terminate() }

        let pid = sleeper.processIdentifier
        XCTAssertTrue(InstanceLock.isMicWarmProcess(pid, executableName: "sleep"))
        XCTAssertFalse(InstanceLock.isMicWarmProcess(pid))
        XCTAssertFalse(InstanceLock.isMicWarmProcess(getpid()))
        XCTAssertFalse(InstanceLock.isMicWarmProcess(0))
        XCTAssertFalse(InstanceLock.isMicWarmProcess(-1))
        XCTAssertFalse(InstanceLock.isMicWarmProcess(1, executableName: "launchd"))  // root-owned
    }
}
