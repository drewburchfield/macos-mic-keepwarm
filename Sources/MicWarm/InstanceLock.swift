import Darwin
import Foundation

/// Keep the descriptor open for the process lifetime. Never unlink the lock file:
/// a replacement inode would let two processes both hold an exclusive lock.
final class InstanceLock {
    enum Failure: Error, CustomStringConvertible {
        case alreadyRunning
        case systemCall(String, Int32)
        case unsafeFile

        var description: String {
            switch self {
            case .alreadyRunning:
                return "Another mic-warm instance is already running"
            case let .systemCall(operation, code):
                return "\(operation): \(String(cString: strerror(code)))"
            case .unsafeFile:
                return "Instance lock must be a regular, single-link file owned by the current user"
            }
        }
    }

    static func defaultURL() throws -> URL {
        // Resolve the account home rather than TMPDIR so a shell and a
        // LaunchAgent agree on the same lock, even with different environments.
        guard let home = getpwuid(geteuid())?.pointee.pw_dir else {
            throw Failure.systemCall("locate account home", ENOENT)
        }
        let cache = URL(fileURLWithPath: String(cString: home), isDirectory: true)
            .appendingPathComponent("Library/Caches", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        return cache
            .appendingPathComponent("mic-warm.lock")
    }

    private let descriptor: Int32

    init(at url: URL? = nil) throws {
        let lockURL = try url ?? Self.defaultURL()
        let fd = open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure.systemCall("open instance lock", errno) }
        do {
            var info = stat()
            guard fstat(fd, &info) == 0 else {
                throw Failure.systemCall("inspect instance lock", errno)
            }
            guard (info.st_mode & S_IFMT) == S_IFREG,
                  info.st_uid == geteuid(), info.st_nlink == 1 else {
                throw Failure.unsafeFile
            }
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
                let code = errno
                if code == EWOULDBLOCK { throw Failure.alreadyRunning }
                throw Failure.systemCall("acquire instance lock", code)
            }
            descriptor = fd
        } catch {
            close(fd)
            throw error
        }
    }

    deinit {
        close(descriptor)
    }
}
