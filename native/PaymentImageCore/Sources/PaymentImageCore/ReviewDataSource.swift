import Foundation

public enum ReviewDataSource {
    public final class ReadPin: @unchecked Sendable {
        private let lease: WorkspaceReaderLease?
        fileprivate init(_ lease: WorkspaceReaderLease?) { self.lease = lease }
    }
    /// Asset work can outlive a UI selection. Pin its immutable source tree
    /// until decoding finishes; standalone review folders have no collector.
    public static func pinReview(_ root: URL) throws -> ReadPin {
        let parent = root.deletingLastPathComponent()
        if root.lastPathComponent == "review", parent.deletingLastPathComponent().lastPathComponent == "states" {
            let workspace = parent.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            try WorkspaceIO.requireUUID(parent.lastPathComponent, field: "state reader")
            return ReadPin(try WorkspaceReaderLease(directory: workspace.appendingPathComponent("device/readers/states"), identity: parent.lastPathComponent))
        }
        if parent.lastPathComponent == "client-views" {
            let device = parent.deletingLastPathComponent()
            try WorkspaceIO.requireUUID(root.lastPathComponent, field: "view reader")
            return ReadPin(try WorkspaceReaderLease(directory: device.appendingPathComponent("readers/views"), identity: root.lastPathComponent))
        }
        return ReadPin(nil)
    }
    public static func assetURL(_ path: String, root: URL) throws -> URL { try EvidencePath.resolve(path, root: root) }
    public static func verifiedAssetURL(_ path: String, hash: String, root: URL) throws -> URL {
        let file = try assetURL(path, root: root)
        try ReviewContentObjectIO.verify(file, hash: hash, maximumBytes: 32 * 1024 * 1024 * 1024)
        return file
    }
    public static func url(_ name: String, root: URL) throws -> URL { try EvidencePath.resolve(name, root: root) }
}
