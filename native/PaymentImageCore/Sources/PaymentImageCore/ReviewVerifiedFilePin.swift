import Foundation
import Darwin

/// A scheduling fence for bytes already hash-verified in this process. It can
/// never establish qualification for a new file or survive process restart.
internal struct ReviewVerifiedFilePin: Sendable, Equatable {
    let device: UInt64, inode: UInt64, size: Int64, mode: UInt32
    let modifiedSeconds: Int64, modifiedNanos: Int64, changedSeconds: Int64, changedNanos: Int64
    static func read(_ file: URL) throws -> Self {
        try WorkspaceIO.rejectSymlinks(file)
        let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw WorkspaceError.io("content file fence") }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size >= 0 else { throw WorkspaceError.invalid("content requires regular file") }
        return Self(device: UInt64(info.st_dev), inode: UInt64(info.st_ino), size: Int64(info.st_size), mode: UInt32(info.st_mode),
                    modifiedSeconds: Int64(info.st_mtimespec.tv_sec), modifiedNanos: Int64(info.st_mtimespec.tv_nsec),
                    changedSeconds: Int64(info.st_ctimespec.tv_sec), changedNanos: Int64(info.st_ctimespec.tv_nsec))
    }
    static func verified(_ file: URL, hash: String, maximumBytes: Int64 = 100 * 1024 * 1024 * 1024) throws -> Self {
        let before = try read(file)
        try ReviewContentObjectIO.verify(file, hash: hash, maximumBytes: maximumBytes)
        guard before == (try read(file)) else { throw WorkspaceError.invalid("content bytes changed during verification") }
        return before
    }
}

