import Foundation
import PaymentImageCore

@main struct SyncHost {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        do {
            guard let command = args.first else { throw WorkspaceError.invalid(usage) }
            switch command {
            case "--backup-household":
                guard args.count == 3 else { throw WorkspaceError.invalid(usage) }
                try HouseholdWorkBackup.export(paths: WorkspacePaths(workspace: URL(fileURLWithPath: args[1])), destination: URL(fileURLWithPath: args[2]))
                print("Current household work backup saved")
            case "--restore-household":
                guard args.count == 3 else { throw WorkspaceError.invalid(usage) }
                _ = try HouseholdWorkBackup.restore(package: URL(fileURLWithPath: args[1]), destination: URL(fileURLWithPath: args[2]))
                print("Writable household restored; establish a new sync directory explicitly")
            case "--select-workspace":
                guard args.count == 2 else { throw WorkspaceError.invalid(usage) }
                let paths = try WorkspacePaths(workspace: URL(fileURLWithPath: args[1]))
                let state = try paths.readState(), locations = try AppStorageLocations.forCurrentProcess()
                guard let container = try locations.managedContainerID(for: paths.workspace) else { throw WorkspaceError.invalid("Use an existing managed workspace") }
                try WorkspaceCompatibility.requireWriter(paths: paths, state: state)
                try WorkspaceBusinessValidator.validateRead(state)
                try AppStorageIndex(locations: locations).select(containerID: container, shape: .workspace)
                print("Selected current household")
            case "--create-family":
                guard args.count == 3 else { throw WorkspaceError.invalid(usage) }
                let paths = try WorkspacePaths(workspace: URL(fileURLWithPath: args[1]))
                let connection = try ReviewFamilyHost.create(paths: paths, remote: URL(fileURLWithPath: args[2]))
                print("Created household: " + connection.selection.bindingID)
            case "--sync-family", "--run-family":
                guard args.count == 2 else { throw WorkspaceError.invalid(usage) }
                let paths = try WorkspacePaths(workspace: URL(fileURLWithPath: args[1]))
                guard let connection = try ReviewFamilyHost.readConnection(paths: paths) else { throw WorkspaceError.invalid("Explicit family connection required") }
                let driver = try ReviewFamilySyncDriver(paths: paths, connection: connection)
                repeat {
                    _ = try await driver.synchronize()
                    if try await driver.hasPendingRequests() {
                        try await driver.processRequests(runtime: ProcessorRuntime.resolve())
                        _ = try await driver.synchronize()
                    }
                    if command == "--sync-family" { break }
                    try await Task.sleep(for: .seconds(3))
                } while !Task.isCancelled
            default: throw WorkspaceError.invalid(usage)
            }
        } catch { print("Stopped: " + error.localizedDescription); exit(1) }
    }
    private static let usage = "--backup-household WORKSPACE NEW_PACKAGE | --restore-household PACKAGE NEW_WORKSPACE | --select-workspace WORKSPACE | --create-family WORKSPACE EMPTY_PROVIDER | --sync-family WORKSPACE | --run-family WORKSPACE"
}
