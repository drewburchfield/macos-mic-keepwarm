import Darwin
import Foundation

/// Size caps for mic-warm's log files, so a long-running install cannot fill the disk.
/// Each log keeps the current file plus one `.1` predecessor.
public enum LogRotation {
    public static let maxBytes: off_t = 10 * 1024 * 1024

    public enum Result: Equatable {
        case notNeeded
        case rotated
        /// The step that failed and its errno description.
        case failed(String)
    }

    /// Renames `path` to `path.1` (replacing any previous `.1`) when it exceeds `limit`, or
    /// when appending `incoming` more bytes would.
    @discardableResult
    public static func rotateIfNeeded(_ path: String, limit: off_t = maxBytes, incoming: off_t = 0) -> Result {
        var st = stat()
        guard stat(path, &st) == 0, st.st_size > 0, st.st_size + incoming > limit else { return .notNeeded }
        return rename(path, path + ".1") == 0 ? .rotated : failure("rename")
    }

    /// Rotates a log that this process writes through inherited file descriptors, as with
    /// launchd's StandardOutPath/StandardErrorPath. Each fd that refers to the file at `path`
    /// is pointed at a fresh file there. Leaves terminals, pipes and other files alone.
    ///
    /// The fresh file is opened before anything is renamed, so a failure leaves `path` in
    /// place and the next call can try again.
    @discardableResult
    public static func rotateInheritedLog(_ path: String, fds: [Int32] = [STDOUT_FILENO, STDERR_FILENO],
                                          limit: off_t = maxBytes, mode: mode_t = 0o644) -> Result {
        var file = stat()
        guard stat(path, &file) == 0, file.st_size > limit else { return .notNeeded }
        let matching = fds.filter { fd in
            var st = stat()
            return fstat(fd, &st) == 0 && (st.st_mode & S_IFMT) == S_IFREG
                && st.st_dev == file.st_dev && st.st_ino == file.st_ino
        }
        guard !matching.isEmpty else { return .notNeeded }

        let staging = path + ".new"
        let fresh = open(staging, O_WRONLY | O_CREAT | O_TRUNC | O_APPEND, mode)
        guard fresh >= 0 else { return failure("open") }
        defer { close(fresh) }
        guard rename(path, path + ".1") == 0 else {
            let result = failure("rename")
            unlink(staging)
            return result
        }
        guard rename(staging, path) == 0 else {
            let result = failure("rename staging")
            rename(path + ".1", path)  // put the live log back so rotation can retry
            unlink(staging)
            return result
        }
        // dup2 swaps the descriptor atomically; a write in flight lands in one file or the other.
        for fd in matching {
            var rc: Int32
            repeat { rc = dup2(fresh, fd) } while rc == -1 && errno == EINTR
            if rc == -1 { return failure("dup2") }
        }
        return .rotated
    }

    private static func failure(_ step: String) -> Result {
        .failed("\(step): \(String(cString: strerror(errno)))")
    }
}
