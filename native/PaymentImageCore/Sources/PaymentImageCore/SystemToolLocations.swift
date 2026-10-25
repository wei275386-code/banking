import Foundation
import Darwin

/// OS-provided utility search path. A bundled processor never inherits a
/// developer's PATH merely to locate platform utilities.
public enum SystemToolLocations {
    public static func searchPath() throws -> String {
        let count = confstr(_CS_PATH, nil, 0)
        guard count > 1, count < 65536 else { throw WorkspaceError.io("OS utility path unavailable") }
        var bytes = [CChar](repeating: 0, count: count)
        guard confstr(_CS_PATH, &bytes, count) == count else { throw WorkspaceError.io("OS utility path changed") }
        return String(decoding: bytes.dropLast().map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
    public static func executable(_ name: String, searchPath: String? = nil) throws -> URL {
        guard !name.isEmpty, !name.contains("/"), !name.contains("\\"), !name.contains("\0") else { throw WorkspaceError.invalid("tool name") }
        let search = try searchPath ?? self.searchPath()
        for directory in search.split(separator: ":") {
            let path = String(directory)
            guard path.hasPrefix("/") else { continue }
            let file = URL(fileURLWithPath: path).appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory), !isDirectory.boolValue,
               FileManager.default.isExecutableFile(atPath: file.path) { return file }
        }
        throw WorkspaceError.io("tool unavailable: " + name)
    }
}
