import Foundation
import CryptoKit
import Darwin

/// Constant-memory immutable copy shared by request originals and client views.
/// It owns no maintenance token and checks cancellation between 1 MiB chunks.
internal enum ReviewContentObjectIO {
    private static func reader(_ file: URL, maximumBytes: Int64) throws -> FileHandle {
        try WorkspaceIO.rejectSymlinks(file)
        let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: file.path]) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size >= 0, info.st_size <= maximumBytes else {
            close(descriptor); throw WorkspaceError.invalid("content object is not a bounded regular file")
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }
    static func verify(_ file: URL, hash: String, maximumBytes: Int64) throws {
        guard try self.hash(file, maximumBytes: maximumBytes) == hash else { throw WorkspaceError.invalid("immutable content collision") }
    }
    static func hash(_ file: URL, maximumBytes: Int64) throws -> String {
        let input = try reader(file, maximumBytes: maximumBytes); defer { try? input.close() }
        var digest = SHA256(), count: Int64 = 0
        while try autoreleasepool(invoking: {
            guard let bytes = try input.read(upToCount: 1024 * 1024), !bytes.isEmpty else { return false }
            try Task.checkCancellation(); count += Int64(bytes.count)
            guard count <= maximumBytes else { throw WorkspaceError.invalid("content object grew beyond budget") }
            digest.update(data: bytes)
            return true
        }) {}
        return digest.finalize().map({ String(format: "%02x", $0) }).joined()
    }
    /// One provider claim covers the immutable object batch. Reacquiring a write
    /// claim on the whole directory for every object serializes with FileProvider
    /// uploads and can turn a small household publication into hours of waiting.
    static func copyBatch(_ sources: [String: URL], to directory: URL) throws {
        try WorkspaceIO.rejectSymlinks(directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Reading existing provider files while holding the directory write
        // claim can block FileProvider materialization/upload bookkeeping.
        // Verify them under leaf read claims, then fence those exact files.
        var existing = [String: ReviewVerifiedFilePin]()
        for hash in sources.keys.sorted() {
            try WorkspaceIO.requireHash(hash)
            let target = directory.appendingPathComponent(hash)
            if FileManager.default.fileExists(atPath: target.path) {
                existing[hash] = try autoreleasepool {
                    try ReviewSyncIO.coordinate(target) { _ in
                        try ReviewVerifiedFilePin.verified(target, hash: hash)
                    }
                }
            }
        }
        try ReviewSyncIO.coordinate(directory, write: true) { _ in
            for hash in sources.keys.sorted() {
                try autoreleasepool {
                    let target = directory.appendingPathComponent(hash)
                    if let pin = existing[hash] {
                        guard try ReviewVerifiedFilePin.read(target) == pin else { throw WorkspaceError.stalePointer }
                    } else {
                        try copy(sources[hash]!, to: target, hash: hash, coordinateDirectory: false)
                    }
                }
            }
            try WorkspaceIO.syncDirectory(directory)
        }
    }
    static func copy(_ source: URL, to destination: URL, hash: String, maximumBytes: Int64 = 32 * 1024 * 1024 * 1024) throws {
        try copy(source, to: destination, hash: hash, maximumBytes: maximumBytes, coordinateDirectory: true)
    }
    private static func copy(_ source: URL, to destination: URL, hash: String, maximumBytes: Int64 = 32 * 1024 * 1024 * 1024, coordinateDirectory: Bool) throws {
        try WorkspaceIO.requireHash(hash); try WorkspaceIO.rejectSymlinks(source); try WorkspaceIO.rejectSymlinks(destination)
        // Reject special files before NSFileCoordinator consults provider/file
        // services. Re-open and fstat its coordinated path below to close races.
        let preflight = try reader(source, maximumBytes: maximumBytes); try preflight.close()
        try ReviewSyncIO.coordinate(source) { _ in
            // Coordinator may return Foundation's OS-directory alias. Reopen only the
            // selected physical path after coordination; never follow that alias.
            let reader = try reader(source, maximumBytes: maximumBytes)
            defer { try? reader.close() }
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let install = { () throws -> Void in
                let parent = destination.deletingLastPathComponent()
                let target = parent.appendingPathComponent(destination.lastPathComponent)
                if FileManager.default.fileExists(atPath: target.path) {
                    try verify(target, hash: hash, maximumBytes: maximumBytes); return
                }
                let temporary = parent.appendingPathComponent(".object-" + UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: temporary) }
                // Independent APFS inodes share unchanged immutable blocks.
                // Always hash the resulting bytes before atomic publication.
                if clonefile(source.path, temporary.path, 0) == 0 {
                    try verify(temporary, hash: hash, maximumBytes: maximumBytes)
                    let cloned = try Self.reader(temporary, maximumBytes: maximumBytes)
                    defer { try? cloned.close() }
                    try cloned.synchronize(); try Task.checkCancellation()
                    try FileManager.default.moveItem(at: temporary, to: target)
                    try WorkspaceIO.syncDirectory(parent)
                    return
                }
                let cloneError = errno
                guard [EXDEV, ENOTSUP, EINVAL, EPERM].contains(cloneError) else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(cloneError), userInfo: [NSFilePathErrorKey: temporary.path])
                }
                let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_NONBLOCK, 0o600)
                guard descriptor >= 0 else { throw WorkspaceError.io("content staging") }
                let writer = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
                defer { try? writer.close() }
                var digest = SHA256(), count: Int64 = 0
                while try autoreleasepool(invoking: {
                    guard let bytes = try reader.read(upToCount: 1024 * 1024), !bytes.isEmpty else { return false }
                    try Task.checkCancellation(); count += Int64(bytes.count)
                    guard count <= maximumBytes else { throw WorkspaceError.invalid("content object grew beyond budget") }
                    digest.update(data: bytes); try writer.write(contentsOf: bytes)
                    return true
                }) {}
                guard digest.finalize().map({ String(format: "%02x", $0) }).joined() == hash else { throw WorkspaceError.invalid("content raw hash") }
                try writer.synchronize(); try Task.checkCancellation()
                try FileManager.default.moveItem(at: temporary, to: target); try WorkspaceIO.syncDirectory(parent)
            }
            if coordinateDirectory {
                try ReviewSyncIO.coordinate(destination.deletingLastPathComponent(), write: true) { _ in try install() }
            } else { try install() }
        }
    }
}
