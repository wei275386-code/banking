import Foundation

/// Installation identity belongs to local device data and is never restored as host authority.
public enum ReviewDeviceIdentity {
    public static func readOrCreate(paths: WorkspacePaths, token: WorkspaceWriteToken) throws -> String {
        try token.validate(for: paths)
        let file = paths.device.appendingPathComponent("device-identity.json")
        if FileManager.default.fileExists(atPath: file.path) {
            let document = try WorkspaceIO.object(WorkspaceIO.read(file))
            guard Set(document.keys) == ["device_id"] else { throw WorkspaceError.invalid("device identity fields") }
            let value = try WorkspaceIO.string(document, "device_id")
            try WorkspaceIO.requireUUID(value, field: "device_id")
            return value
        }
        let value = UUID().uuidString.lowercased()
        try WorkspaceIO.atomicWrite(WorkspaceIO.canonical(["device_id": value]), to: file)
        return value
    }
}
