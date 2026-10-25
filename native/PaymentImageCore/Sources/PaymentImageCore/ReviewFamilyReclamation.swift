import Foundation

/// A successful complete publication is the only trigger for provider cleanup.
/// Pending transport envelopes publish their references before their objects.
internal enum ReviewFamilyReclamation {
    struct Result: Sendable { let snapshots: Int, objects: Int }
    @discardableResult static func collect(remote: URL, selection: ReviewFamilyBindingSelection, expectedGeneration: String) throws -> Result {
        try WorkspaceIO.requireHash(expectedGeneration)
        return try ReviewSyncIO.coordinate(remote, write: true) { root in
            try selection.validate(marker: ReviewSyncIO.read(root.appendingPathComponent("family.json"), limit: 4096))
            let pointer = try WorkspaceIO.object(ReviewSyncIO.read(root.appendingPathComponent("current.json"), limit: 4096))
            guard pointer["generation"] as? String == expectedGeneration else { throw WorkspaceError.stalePointer }
            let raw = try ReviewSyncIO.read(root.appendingPathComponent("snapshots/" + expectedGeneration), limit: ReviewClientBusinessProof.maximumBytes)
            guard WorkspaceIO.digest(raw) == expectedGeneration else { throw WorkspaceError.invalid("reclamation snapshot pin") }
            let snapshot = try WorkspaceIO.object(raw)
            guard let files = snapshot["files"] as? [String: String] else { throw WorkspaceError.invalid("reclamation snapshot files") }
            var keep = Set(files.values)
            let inventory = try WorkspaceIO.string(snapshot, "covered_revision_inventory")
            keep.insert(inventory)
            func metadata(_ hash: String) throws -> [String: Any] {
                try WorkspaceIO.requireHash(hash)
                let raw = try ReviewSyncIO.read(root.appendingPathComponent("objects/" + hash), limit: ReviewClientBusinessProof.maximumBytes)
                guard WorkspaceIO.digest(raw) == hash else { throw WorkspaceError.invalid("reclamation metadata hash") }
                return try WorkspaceIO.object(raw)
            }
            guard let tuple = snapshot["state"] as? [String: Any],
                  let stateFiles = try metadata(WorkspaceIO.string(tuple, "state_manifest_hash"))["files"] as? [String: String] else { throw WorkspaceError.invalid("reclamation state closure") }
            keep.formUnion(stateFiles.values)
            let assets = try metadata(WorkspaceIO.string(snapshot, "asset_manifest"))
            guard let entries = assets["assets"] as? [[String: Any]], let origins = try metadata(inventory)["entries"] as? [[String: Any]] else { throw WorkspaceError.invalid("reclamation object inventory") }
            for entry in entries { keep.insert(try WorkspaceIO.string(entry, "sha256")) }
            for origin in origins { keep.insert(try WorkspaceIO.string(origin, "payload_hash")) }
            for name in try WorkspaceReclamation.children(root.appendingPathComponent("revisions")) {
                guard name.hasSuffix(".json") else { throw WorkspaceError.invalid("revision envelope name") }
                let row = try WorkspaceIO.object(ReviewSyncIO.read(root.appendingPathComponent("revisions/" + name), limit: 4096))
                guard row["binding_id"] as? String == selection.bindingID else { throw WorkspaceError.invalid("foreign revision during reclamation") }
                keep.insert(try WorkspaceIO.string(row, "payload_hash"))
            }
            for name in try WorkspaceReclamation.children(root.appendingPathComponent("requests")) {
                guard name.hasSuffix(".json") else { throw WorkspaceError.invalid("request envelope name") }
                let row = try WorkspaceIO.object(ReviewSyncIO.read(root.appendingPathComponent("requests/" + name), limit: ReviewFamilyRequestTransport.metadataLimit))
                guard row["binding_id"] as? String == selection.bindingID, let files = row["files"] as? [[String: Any]] else { throw WorkspaceError.invalid("request during reclamation") }
                keep.insert(try WorkspaceIO.string(row, "payload_hash"))
                guard files.count <= 1024 else { throw WorkspaceError.invalid("request reclamation budget") }
                for file in files { keep.insert(try WorkspaceIO.string(file, "sha256")) }
                guard keep.count <= 200_000 else { throw WorkspaceError.invalid("reclamation reference budget") }
            }
            for hash in keep { try WorkspaceIO.requireHash(hash) }
            var snapshots = 0, objects = 0
            for name in try WorkspaceReclamation.children(root.appendingPathComponent("snapshots")) where name != expectedGeneration && !name.hasPrefix(".") {
                try WorkspaceIO.requireHash(name)
                try WorkspaceIO.rejectSymlinks(root.appendingPathComponent("snapshots/" + name))
                try FileManager.default.removeItem(at: root.appendingPathComponent("snapshots/" + name)); snapshots += 1
            }
            for name in try WorkspaceReclamation.children(root.appendingPathComponent("objects")) where !keep.contains(name) && !name.hasPrefix(".") {
                try WorkspaceIO.requireHash(name)
                try WorkspaceIO.rejectSymlinks(root.appendingPathComponent("objects/" + name))
                try FileManager.default.removeItem(at: root.appendingPathComponent("objects/" + name)); objects += 1
            }
            return .init(snapshots: snapshots, objects: objects)
        }
    }
}
