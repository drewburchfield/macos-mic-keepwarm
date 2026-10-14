import Darwin
import Foundation

/// One mic-warm per user, enforced with an advisory `flock` on a file the user owns.
///
/// The kernel drops the lock when its holder exits, however it exits, so a stale file never
/// blocks a new instance and never points us at an unrelated process: the PID inside is only
/// read while some process still holds the lock, and is only signalled after
/// `isMicWarmProcess` confirms it.
public final class InstanceLock {
    public enum Acquisition: Equatable {
        case acquired
        /// Another process holds the lock. The PID it recorded, if readable.
        case held(owner: pid_t?)
        /// The step that failed and its errno description.
        case failed(String)
    }

    public let path: String
    private var fd: Int32 = -1

    public init(path: String) {
        self.path = path
    }

    deinit {
        if fd >= 0 { close(fd) }  // releases the lock
    }

    /// Takes the lock without blocking. On success the lock is held until this object is
    /// released or the process exits, and the file holds this process's PID.
    public func tryAcquire() -> Acquisition {
        if fd < 0 {
            let dir = (path as NSString).deletingLastPathComponent
            do {
                try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
            } catch {
                return .failed("create \(dir): \(error.localizedDescription)")
            }
            // O_NOFOLLOW: refuse a planted symlink. O_CLOEXEC: children must not inherit the lock.
            fd = open(path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
            if fd < 0 { return .failed("open: \(String(cString: strerror(errno)))") }
        }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            if errno == EWOULDBLOCK { return .held(owner: recordedPID()) }
            return .failed("flock: \(String(cString: strerror(errno)))")
        }
        let pid = "\(getpid())\n"
        guard ftruncate(fd, 0) == 0, pwrite(fd, pid, pid.utf8.count, 0) == pid.utf8.count else {
            return .failed("write pid: \(String(cString: strerror(errno)))")
        }
        return .acquired
    }

    private func recordedPID() -> pid_t? {
        var buf = [UInt8](repeating: 0, count: 32)
        let n = pread(fd, &buf, buf.count - 1, 0)
        guard n > 0 else { return nil }
        let text = String(decoding: buf[0..<n], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pid = pid_t(text), pid > 0 else { return nil }
        return pid
    }

    /// Whether `pid` is a live process owned by this user whose executable is named
    /// `executableName`. Guards against signalling a reused PID.
    public static func isMicWarmProcess(_ pid: pid_t, executableName: String = "mic-warm") -> Bool {
        guard pid > 0, pid != getpid() else { return false }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
              info.pbi_uid == getuid() else { return false }
        var pathBuf = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count)) > 0 else { return false }
        let exe = String(cString: pathBuf)
        return (exe as NSString).lastPathComponent == executableName
    }
}
