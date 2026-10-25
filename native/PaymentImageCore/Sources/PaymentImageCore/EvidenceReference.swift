import Foundation
import Darwin

public struct EvidenceAsset: Codable, Sendable, Equatable {
    public let path: String
    public let sha256: String
}

public struct EvidenceSource: Codable, Sendable, Equatable {
    public let path: String
    public let sha256: String
    public let original_name: String
}

public struct EvidenceReference: Codable, Sendable, Equatable {
    public let kind: String
    public let preview: EvidenceAsset?
    public let raw: EvidenceAsset?
    public let image: EvidenceAsset?
    public let source: EvidenceSource?
    public let crop_complete: Bool?
    public let ocr_result: EvidenceAsset?
}

public enum EvidencePath {
    /// Resolve within the managed evidence folder. Symlinks must also remain
    /// inside it; opening unrelated local files is never inferred from JSON.
    public static func resolve(_ relative: String, root: URL) throws -> URL {
        let base = try physicalURL(root)
        let components = relative.split(separator: "/")
        guard !relative.hasPrefix("/"), !components.isEmpty, !components.contains("..") else {
            throw NSError(domain: "EvidencePath", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "素材路径超出证据文件夹"])
        }
        var target = base
        for component in components {
            target = try physicalURL(target.appendingPathComponent(String(component)))
            guard target.path.hasPrefix(base.path + "/") else {
                throw NSError(domain: "EvidencePath", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "素材路径超出证据文件夹"])
            }
        }
        return target
    }

    /// Foundation standardization may turn a physical system path back into
    /// /var or /tmp. Resolve links, including missing evidence's existing parent,
    /// then preserve realpath's spelling for the strict workspace reader.
    private static func physicalURL(_ url: URL) throws -> URL {
        var existing = url, missing = [String](), followedLinks = 0
        while true {
            if let resolved = realpath(existing.path, nil) {
                defer { free(resolved) }
                let suffix = missing.reversed().map { "/" + $0 }.joined()
                return URL(fileURLWithPath: String(cString: resolved) + suffix)
            }
            let code = errno
            guard code == ENOENT else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(code)) }
            // A dangling link still has a destination outside the allowed root.
            // Do not treat its name as an ordinary missing path component.
            var info = stat()
            if lstat(existing.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFLNK {
                followedLinks += 1
                guard followedLinks <= 40 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(ELOOP)) }
                let link = try FileManager.default.destinationOfSymbolicLink(atPath: existing.path)
                existing = link.hasPrefix("/") ? URL(fileURLWithPath: link) : existing.deletingLastPathComponent().appendingPathComponent(link)
                continue
            }
            let parent = existing.deletingLastPathComponent()
            guard parent.path != existing.path else { throw WorkspaceError.io("evidence root unavailable") }
            missing.append(existing.lastPathComponent)
            existing = parent
        }
    }
}
