import Darwin
import Foundation

/// Size caps for mic-warm's log files, so a long-running install cannot fill the disk.
/// Each log keeps the current file plus one `.1` predecessor.
public enum LogRotation {
    public static let maxBytes: off_t = 10 * 1024 * 1024

    /// Renames `path` to `path.1` (replacing any previous `.1`) when it exceeds `limit`.
    /// Returns true if it rotated.
    @discardableResult
    public static func rotateIfNeeded(_ path: String, limit: off_t = maxBytes) -> Bool {
        var st = stat()
        guard stat(path, &st) == 0, st.st_size > limit else { return false }
        return rename(path, path + ".1") == 0
    }

    /// Rotates a log that this process writes through inherited file descriptors, as with
    /// launchd's StandardOutPath/StandardErrorPath. Each fd that refers to the file at `path`
    /// is pointed at a fresh file there. Leaves terminals, pipes and other files alone.
    /// Returns true if it rotated.
    @discardableResult
    public static func rotateInheritedLog(_ path: String, fds: [Int32] = [STDOUT_FILENO, STDERR_FILENO],
                                          limit: off_t = maxBytes, mode: mode_t = 0o644) -> Bool {
        var file = stat()
        guard stat(path, &file) == 0, file.st_size > limit else { return false }
        let matching = fds.filter { fd in
            var st = stat()
            return fstat(fd, &st) == 0 && (st.st_mode & S_IFMT) == S_IFREG
                && st.st_dev == file.st_dev && st.st_ino == file.st_ino
        }
        guard !matching.isEmpty, rename(path, path + ".1") == 0 else { return false }
        let fresh = open(path, O_WRONLY | O_CREAT | O_APPEND, mode)
        guard fresh >= 0 else { return false }
        // dup2 swaps the descriptor atomically; a write in flight lands in one file or the other.
        for fd in matching { dup2(fresh, fd) }
        close(fresh)
        return true
    }
}
