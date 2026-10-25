import Foundation
import CryptoKit
import Darwin

/// Banking protocol inspired by Cubic: coordinated provider I/O, immutable operations,
/// local credentials, and a durable outbox. No SQLite file is shared between devices.
public enum ReviewSyncIO {
    public static func coordinate<T>(_ url: URL, write: Bool = false, _ body: (URL) throws -> T) throws -> T {
        var result: Result<T, Error>?
        var error: NSError?
        let coordinator = NSFileCoordinator()
        if write { coordinator.coordinate(writingItemAt: url, options: [], error: &error) { coordinated in result = Result { try body(coordinated) } } }
        else { coordinator.coordinate(readingItemAt: url, options: [], error: &error) { coordinated in result = Result { try body(coordinated) } } }
        if let error { throw error }
        guard let result else { throw CocoaError(.fileReadUnknown) }
        return try result.get()
    }
    public static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    public static func read(_ url: URL, limit: Int = 40_000_000) throws -> Data {
        func boundedReader(_ file: URL) throws -> FileHandle {
            try WorkspaceIO.rejectSymlinks(file)
            let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: file.path]) }
            var info = stat()
            guard limit >= 0, fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
                  info.st_size >= 0, info.st_size <= Int64(limit) else {
                close(descriptor); throw CocoaError(.fileReadCorruptFile)
            }
            return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        }
        // Reject FIFO/device/directory before provider coordination can block.
        let preflight = try boundedReader(url); try preflight.close()
        return try coordinate(url) { _ in
            // Foundation may return an OS alias for the selected physical path.
            // Reopen the original path with the same strict descriptor checks.
            let handle = try boundedReader(url); defer { try? handle.close() }
            var data = Data()
            while let bytes = try handle.read(upToCount: min(1024 * 1024, limit - data.count + 1)), !bytes.isEmpty {
                try Task.checkCancellation()
                guard data.count + bytes.count <= limit else { throw CocoaError(.fileReadTooLarge) }
                data.append(bytes)
            }
            return data
        }
    }
    /// Store `data` under its own SHA256 name without changing its bytes.
    public static func storeContentAddressed(_ data: Data, at file: URL) throws {
        guard digest(data) == file.lastPathComponent else { throw CocoaError(.fileWriteInvalidFileName) }
        try coordinate(file.deletingLastPathComponent(), write: true) { parent in
            let destination = parent.appendingPathComponent(file.lastPathComponent)
            let directoryValues = try parent.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard directoryValues.isDirectory == true, directoryValues.isSymbolicLink != true else { throw CocoaError(.fileWriteNoPermission) }
            if FileManager.default.fileExists(atPath: destination.path) {
                let values = try destination.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else { throw CocoaError(.fileWriteFileExists) }
                if values.fileSize == data.count, try Data(contentsOf: destination) == data { return }
            }
            let stage = parent.appendingPathComponent(".upload-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: stage) }
            try data.write(to: stage, options: .atomic)
            guard try digestFile(stage) == file.lastPathComponent else { throw CocoaError(.fileReadCorruptFile) }
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: stage)
            } else {
                try FileManager.default.moveItem(at: stage, to: destination)
            }
        }
    }
    /// Preserve supplied bytes. Existing files can be JSON-equivalent, but are never rewritten.
    public static func immutable(_ data: Data, at file: URL) throws {
        try coordinate(file.deletingLastPathComponent(), write: true) { parent in
            let destination = parent.appendingPathComponent(file.lastPathComponent)
            let directoryValues = try parent.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard directoryValues.isDirectory == true, directoryValues.isSymbolicLink != true else { throw CocoaError(.fileWriteNoPermission) }
            if FileManager.default.fileExists(atPath: destination.path) {
                let values = try destination.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else { throw CocoaError(.fileWriteFileExists) }
                let existing = try Data(contentsOf: destination)
                if existing != data {
                    guard let a = try? JSONSerialization.jsonObject(with: existing, options: [.fragmentsAllowed]),
                          let b = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
                          try json(a) == json(b) else { throw CocoaError(.fileWriteFileExists) }
                }
                return
            }
            let stage = parent.appendingPathComponent(".upload-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: stage) }
            try data.write(to: stage, options: .atomic)
            try FileManager.default.moveItem(at: stage, to: destination)
        }
    }
    public static func digestFile(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hash = SHA256()
        while let bytes = try handle.read(upToCount: 1_048_576), !bytes.isEmpty { hash.update(data: bytes) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    public static func copyImmutable(_ source: URL, at destination: URL, hash: String) throws {
        try coordinate(source) { input in
            guard try digestFile(input) == hash else { throw CocoaError(.fileReadCorruptFile) }
            try coordinate(destination.deletingLastPathComponent(), write: true) { parent in
                let target = parent.appendingPathComponent(destination.lastPathComponent)
                if FileManager.default.fileExists(atPath: target.path) {
                    guard try digestFile(target) == hash else { throw CocoaError(.fileReadCorruptFile) }; return
                }
                let stage = parent.appendingPathComponent(".upload-" + UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: stage) }
                try FileManager.default.copyItem(at: input, to: stage)
                guard try digestFile(stage) == hash else { throw CocoaError(.fileReadCorruptFile) }
                try FileManager.default.moveItem(at: stage, to: target)
            }
        }
    }
    public static func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]) }
    public static func isMissing(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) { return true }
        if error.domain == NSPOSIXErrorDomain && error.code == 2 { return true }
        return (error.userInfo[NSUnderlyingErrorKey] as? NSError).map { isMissing($0) } ?? false
    }
}

