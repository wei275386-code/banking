import Foundation
import Darwin

/// Shared by the macOS app and sync host. The lock releases automatically after a crash.
public final class ReviewProcessLease: @unchecked Sendable {
    private let descriptor: Int32
    public init(root: URL, name: String = "processor") throws {
        guard !name.isEmpty, name.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let opened = open(root.appendingPathComponent(".review-" + name + ".lock").path,
                          O_CREAT | O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard opened >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        var info = stat()
        guard fstat(opened, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            close(opened); throw CocoaError(.fileWriteNoPermission)
        }
        descriptor = opened
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw NSError(domain: "Processor", code: 1, userInfo: [NSLocalizedDescriptionKey: "另一项导入或复核正在处理，请完成后重试。"])
        }
    }
    #if os(macOS)
    /// Pass this handle as Process.standardInput. The child shares the lock's open
    /// file description, so an App crash cannot release a still-running processor.
    public func childGuardHandle() throws -> FileHandle {
        let inherited = dup(descriptor)
        guard inherited >= 0 else { throw CocoaError(.fileReadUnknown) }
        return FileHandle(fileDescriptor: inherited, closeOnDealloc: true)
    }
    #endif
    deinit { close(descriptor) }
}
