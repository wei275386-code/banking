import Foundation

/// Mobile starts without a host ledger. A pre-existing local review copy can
/// remain usable offline; a new checkpoint connection must supply a verified
/// single-snapshot handle before it becomes an editing source.
public enum MobileReviewDataSource: Sendable, Equatable {
    case awaitingCheckpoint
    case localCopy(URL)

    public var localReview: URL? {
        if case .localCopy(let root) = self { return root }
        return nil
    }
}

public struct MobileStoragePlan: Sendable {
    public let root: URL
    public static func resolve(locations: AppStorageLocations, importedWorkspace: String? = nil,
                               qaName: String? = nil) throws -> Self {
        let relative: String
        if let qaName {
            guard locations.domain != .production, !qaName.isEmpty,
                  qaName.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }) else {
                throw WorkspaceError.invalid("mobile QA storage domain")
            }
            relative = qaName
        } else if let importedWorkspace {
            try validateImportedID(importedWorkspace)
            relative = "ImportedReviews/" + importedWorkspace
        } else { relative = locations.domain == .production ? "FamilyReview" : "FamilyReviewQA" }
        return Self(root: try WorkspaceIO.safeChild(locations.support, "Mobile/" + relative))
    }
    public static func importedReviewURL(locations: AppStorageLocations, identity: String) throws -> URL {
        try validateImportedID(identity)
        return try WorkspaceIO.safeChild(locations.support, "Mobile/ImportedReviews/" + identity)
    }
    /// A saved selection is a recovery obligation, not first-launch state.
    /// This performs local reads only and never resolves the provider bookmark.
    public static func requireSelectedImportedStorage(locations: AppStorageLocations, identity: String) throws {
        let root = try importedReviewURL(locations: locations, identity: identity)
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &directory), directory.boolValue else {
            throw WorkspaceError.invalid("已选本机资料目录缺失，请恢复原目录后重试；原选择已保留，不会改为首次连接。")
        }
        if ["financial-review.json", "payment-evidence.json"].allSatisfy({
            FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path)
        }) {
            _ = try MobileBootstrapPolicy.source(at: root)
            return
        }
        let paths = try WorkspacePaths(workspace: root.appendingPathComponent("Client"))
        // A verified offline reader or a valid pending connection can remain
        // usable without the standalone imported reports. Neither grants host.
        if try ReviewFamilyClientSession.read(paths: paths) != nil { return }
        if try ReviewFamilyClientSession.readConnection(paths: paths) != nil { return }
        guard try MobileBootstrapPolicy.source(at: root).localReview != nil else {
            throw WorkspaceError.invalid("已选本机资料副本不完整，请恢复原资料后重试；原选择已保留。")
        }
    }
    private static func validateImportedID(_ identity: String) throws {
        guard identity.count == 64, identity.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw WorkspaceError.invalid("imported review identity")
        }
    }
}

public enum MobileBootstrapPolicy {
    /// Read-only discovery. Missing reports mean onboarding, never permission
    /// to generate financial, banking, workspace or host state on the phone.
    public static func source(at root: URL) throws -> MobileReviewDataSource {
        let fm = FileManager.default
        let files = ["financial-review.json", "payment-evidence.json"].map { root.appendingPathComponent($0) }
        let present = files.map { fm.fileExists(atPath: $0.path) }
        guard present.contains(true) else { return .awaitingCheckpoint }
        guard present.allSatisfy({ $0 }) else { throw WorkspaceError.invalid("本机复盘副本不完整，请重新选择包含财务复盘和交易证据的文件夹。") }
        for file in files {
            let type = try fm.attributesOfItem(atPath: file.path)[.type] as? FileAttributeType
            guard type == .typeRegular else { throw WorkspaceError.invalid("本机复盘文件必须是普通文件。") }
        }
        return .localCopy(root)
    }
}
