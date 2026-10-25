import Foundation
@testable import PaymentImageCore

/// Test inputs always derive from OS APIs or explicit test configuration.
enum TestPlatform {
    static func temporaryDirectory() throws -> URL {
        if let configured = ProcessInfo.processInfo.environment["BANKING_NATIVE_QA_TEMP"] {
            let root = URL(fileURLWithPath: configured, isDirectory: true)
            guard configured.hasPrefix("/"), FileManager.default.fileExists(atPath: root.path) else {
                throw WorkspaceError.invalid("explicit native test temporary directory")
            }
            try WorkspaceIO.rejectSymlinks(root)
            return root
        }
        return try AppStorageLocations.physicalSystemDirectory(FileManager.default.temporaryDirectory)
    }
    static func python(environmentKey: String = "BANKING_REQUEST_PROCESSOR_QA_PYTHON") throws -> URL {
        if let configured = ProcessInfo.processInfo.environment[environmentKey] {
            let url = URL(fileURLWithPath: configured)
            guard configured.hasPrefix("/"), !url.pathComponents.contains(".."),
                  FileManager.default.isExecutableFile(atPath: url.path) else {
                throw WorkspaceError.invalid("invalid explicit test interpreter")
            }
            return url
        }
        return try SystemToolLocations.executable("python3", searchPath: ProcessInfo.processInfo.environment["PATH"])
    }
    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
    static func shellScript(_ body: String) throws -> String {
        "#!" + (try SystemToolLocations.executable("sh")).path + "\n" + body
    }
}
