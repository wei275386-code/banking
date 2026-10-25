#if os(macOS)
import Foundation

/// Process-local first-run proof. This does not grant host authority or replace
/// the current workspace's business/read/write qualification.
public actor WorkspaceRuntimeQualification {
    public enum Result: Sendable, Equatable {
        case qualified(manifestSHA256: String)
        case failure(String)
        case explicitDevelopment
    }
    struct Identity: Sendable, Hashable {
        let workspace: String
        let workspaceID: String
        let bundle: String
        let manifestSHA256: String
    }
    public static let shared = WorkspaceRuntimeQualification()
    private var jobs: [Identity: Task<Result, Never>] = [:]
    public init() {}

    /// A scheduling/cache identity, never processor or host authorization.
    /// The OS-selected launched App is the only root canonicalized here.
    public nonisolated static func launchedManifestSHA256() throws -> String {
        guard Bundle.main.bundleURL.pathExtension.lowercased() == "app" else {
            throw WorkspaceError.invalid("runtime manifest requires the launched App")
        }
        let root = ProcessorRuntime.canonicalAppRoot(Bundle.main.bundleURL)
        let manifest = try WorkspaceIO.safeChild(root, "Contents/Resources/runtime-manifest.json")
        let raw = try WorkspaceIO.read(manifest, limit: 16 * 1024 * 1024)
        try WorkspaceCompatibility.requireRuntime(manifestRaw: raw)
        return WorkspaceIO.digest(raw)
    }

    public func qualify(paths: WorkspacePaths, runtime: ProcessorRuntime) async -> Result {
        if runtime.mode == .development {
            #if DEBUG
            return .explicitDevelopment
            #else
            return .failure("Distribution requires a bundled runtime")
            #endif
        }
        do {
            guard let bundle = runtime.bundleRoot,
                  ProcessorRuntime.canonicalAppRoot(bundle) == ProcessorRuntime.canonicalAppRoot(Bundle.main.bundleURL),
                  bundle.pathExtension == "app" else { throw WorkspaceError.invalid("health requires the launched App") }
            let manifest = bundle.appendingPathComponent("Contents/Resources/runtime-manifest.json")
            let raw = try WorkspaceIO.read(manifest)
            try WorkspaceCompatibility.requireRuntime(manifestRaw: raw)
            let identity = Identity(workspace: paths.workspace.path, workspaceID: try paths.readPointer().workspaceID,
                                    bundle: bundle.path, manifestSHA256: WorkspaceIO.digest(raw))
            return await qualification(identity: identity) {
                do {
                    try WorkspaceHealth.selfTest(runtime: runtime)
                    guard try WorkspaceIO.digest(WorkspaceIO.read(manifest)) == identity.manifestSHA256 else {
                        throw WorkspaceError.invalid("runtime manifest changed during qualification")
                    }
                    return .qualified(manifestSHA256: identity.manifestSHA256)
                } catch { return .failure(error.localizedDescription) }
            }
        } catch { return .failure(error.localizedDescription) }
    }

    /// Explicit invalidation is required after a runtime integrity failure or
    /// workspace replacement. An in-flight caller must also discard stale UI
    /// selection results; cancellation cannot interrupt the bounded subprocess.
    public func invalidate(workspace: URL) {
        let path = WorkspaceIO.lexicalURL(workspace).path
        for identity in jobs.keys.filter({ $0.workspace == path }) {
            jobs.removeValue(forKey: identity)?.cancel()
        }
    }

    func qualification(identity: Identity, worker: @escaping @Sendable () async -> Result) async -> Result {
        if let existing = jobs[identity] { return await existing.value }
        let job = Task.detached(priority: .utility) { await worker() }
        jobs[identity] = job
        return await job.value
    }
}
#endif
