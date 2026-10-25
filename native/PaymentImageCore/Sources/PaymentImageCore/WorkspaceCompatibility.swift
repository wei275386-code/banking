import Foundation

/// A release capability, independent of cloud role or a host grant. Unknown
/// envelopes can be retained/exported but are never opened by a business writer.
public struct WorkspaceCompatibilityDecision: Sendable, Equatable {
    public let readable: Bool
    public let writable: Bool
    public let reasons: [String]
}

public enum WorkspaceCompatibility {
    public static let appVersion = "1.3.0"
    public static let buildNumber = 20
    public static let runtimeVersion = "cpython-3.13.9-pbs-20251014-lock1"

    /// A launched App must agree with the capability compiled by this release.
    /// Standalone package tests/tools deliberately use the compiled capability.
    public static func runningVersion(bundle: Bundle = .main) throws -> String {
        guard bundle.bundleURL.pathExtension.lowercased() == "app" else { return appVersion }
        guard let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
              version == appVersion, build == String(buildNumber) else {
            throw WorkspaceError.unsupportedVersion("App version and compiled capability disagree")
        }
        return version
    }

    public static func requireRuntime(manifestRaw: Data) throws {
        _ = try runningVersion()
        let manifest = try WorkspaceIO.object(manifestRaw)
        guard manifest["runtime_version"] as? String == runtimeVersion else {
            throw WorkspaceError.unsupportedVersion("runtime contract")
        }
    }

    /// Strict numeric three-component versions; malformed versions never fall
    /// back to a lexicographic comparison or silently become version zero.
    public static func supports(minimumVersion: String, runningVersion: String? = nil) throws -> Bool {
        func components(_ value: String) throws -> [UInt64] {
            let parts = value.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 3 else { throw WorkspaceError.invalid("application version") }
            return try parts.map { part in
                guard !part.isEmpty, part.utf8.allSatisfy({ (48...57).contains($0) }),
                      part.count == 1 || part.first != "0", let number = UInt64(part) else {
                    throw WorkspaceError.invalid("application version")
                }
                return number
            }
        }
        let required = try components(minimumVersion), running = try components(runningVersion ?? self.runningVersion())
        return !running.lexicographicallyPrecedes(required)
    }

    public static func evaluate(minimumReader: String? = nil, minimumWriter: String? = nil,
                                runningVersion: String? = nil) throws -> WorkspaceCompatibilityDecision {
        let running = try runningVersion ?? self.runningVersion()
        let readable = try minimumReader.map { try supports(minimumVersion: $0, runningVersion: running) } ?? true
        let writable = try readable && (minimumWriter.map { try supports(minimumVersion: $0, runningVersion: running) } ?? true)
        return .init(readable: readable, writable: writable, reasons: writable ? [] : ["requires a newer App"])
    }
    public static func decision(paths: WorkspacePaths, state: StateHandle? = nil) throws -> WorkspaceCompatibilityDecision {
        let document = try WorkspaceIO.object(WorkspaceIO.read(paths.metadata))
        guard Set(document.keys).isSubset(of: ["workspace_id", "created_at", "metadata", "access", "min_reader_version", "min_writer_version"]) else {
            throw WorkspaceError.invalid("workspace fields")
        }
        func minimum(_ key: String) throws -> String? {
            guard let value = document[key] else { return nil }
            guard let text = value as? String else { throw WorkspaceError.invalid(key) }
            return text
        }
        let decision = try evaluate(minimumReader: minimum("min_reader_version"), minimumWriter: minimum("min_writer_version"))
        let access = document["access"] as? String ?? "writable"
        guard ["writable", "viewing"].contains(access) else { throw WorkspaceError.invalid("workspace access") }
        return .init(readable: decision.readable, writable: decision.writable && access == "writable",
                     reasons: decision.reasons + (access == "viewing" ? ["viewing copy"] : []))
    }

    public static func requireWriter(paths: WorkspacePaths, state: StateHandle? = nil) throws {
        let decision = try decision(paths: paths, state: state)
        guard decision.writable else { throw WorkspaceError.unsupportedVersion(decision.reasons.joined(separator: "; ")) }
    }

    public static func isViewingCopy(paths: WorkspacePaths) throws -> Bool {
        try WorkspaceIO.object(WorkspaceIO.read(paths.metadata))["access"] as? String == "viewing"
    }
}
