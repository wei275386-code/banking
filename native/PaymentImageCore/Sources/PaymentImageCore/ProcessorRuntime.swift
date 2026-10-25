#if os(macOS)
import Foundation
import CryptoKit
import Darwin

public struct ProcessorRuntimeError: LocalizedError, Sendable {
    public enum Code: String, Sendable {
        case manifestMissing, manifestInvalid, runtimeIntegrity, developmentRequired, developmentInvalid
        case dataRootRequired, invalidDataRoot
    }
    public let code: Code
    public let detail: String
    public init(_ code: Code, _ detail: String) { self.code = code; self.detail = detail }
    public var errorDescription: String? { "\(detail) [\(code.rawValue)]" }
}

/// Read-only code locations. Business state is supplied separately to ProcessorExecution.
public struct ProcessorRuntime: Sendable, Equatable {
    public enum Mode: String, Sendable { case bundled, development }
    public let mode: Mode
    public let codeRoot: URL
    public let scripts: URL
    public let python: URL
    public let helper: URL?
    public let defaults: URL?
    public let bundleRoot: URL?
    public let bootstrap: URL?
    public let runtimeVersion: String?
    private let manifestURL: URL?
    private let manifestSHA256: String?
    /// Explicit development configuration; never use this as bundled business data.
    public var project: URL { codeRoot }

    public init(project: URL, python: URL) throws {
        #if !DEBUG
        throw ProcessorRuntimeError(.developmentRequired, "Distribution 构建不接受 development runtime。")
        #else
        let scripts = project.appendingPathComponent("scripts")
        var isDirectory: ObjCBool = false
        guard FileManager.default.isExecutableFile(atPath: python.path),
              FileManager.default.fileExists(atPath: scripts.path, isDirectory: &isDirectory), isDirectory.boolValue
        else { throw ProcessorRuntimeError(.developmentInvalid, "处理器 development runtime 或代码目录无效。") }
        // Keep physical OS spelling and a consistent directory hint across direct
        // and JSON-configured construction. Foundation standardization can alias
        // a physical temporary directory back to a system symlink.
        mode = .development; codeRoot = WorkspaceIO.lexicalURL(project)
        self.scripts = WorkspaceIO.lexicalURL(scripts)
        self.python = WorkspaceIO.lexicalURL(python); helper = nil; defaults = nil
        bundleRoot = nil; bootstrap = nil; runtimeVersion = nil; manifestURL = nil; manifestSHA256 = nil
        #endif
    }

    /// A bundle manifest always takes precedence. A packaged App cannot select an external runtime.
    /// Source execution requires an explicit project or config; there is no current-directory fallback.
    public static func resolve(project: URL? = nil, bundle: Bundle = .main,
                               environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Self {
        let runtimeRoot: URL
        if bundle.bundleURL.pathExtension.lowercased() == "app" { runtimeRoot = canonicalAppRoot(bundle.bundleURL) }
        else { runtimeRoot = try containingApp(executable: bundle.executableURL) ?? bundle.bundleURL }
        let manifest = runtimeRoot.appendingPathComponent("Contents/Resources/runtime-manifest.json")
        if FileManager.default.fileExists(atPath: manifest.path) {
            return try bundled(root: runtimeRoot, manifest: manifest)
        }
        if runtimeRoot.pathExtension.lowercased() == "app" {
            throw ProcessorRuntimeError(.manifestMissing, "App bundle 缺少 runtime-manifest.json，请重新安装完整应用。")
        }
        // Distribution executables must not opt into development via environment variables.
        #if !DEBUG
        throw ProcessorRuntimeError(.developmentRequired, "Distribution runtime 必须由 App bundle manifest 配置。")
        #else
        guard project != nil || environment["BANKING_PROCESSOR_CONFIG"] != nil else {
            throw ProcessorRuntimeError(.developmentRequired, "Development runtime 必须显式指定 project 或 config。")
        }
        let root = environment["BANKING_PROCESSOR_PROJECT"].map { URL(fileURLWithPath: $0) } ?? project
        let config: URL?
        if let path = environment["BANKING_PROCESSOR_CONFIG"] { config = URL(fileURLWithPath: path) }
        else if let resource = bundle.url(forResource: "processor-location", withExtension: "json") { config = resource }
        else if let root {
            let candidate = root.appendingPathComponent("config/processor-location.json")
            config = FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
        } else { config = nil }
        if let config {
            let values = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: config))
            guard let projectPath = values["project"], let pythonPath = values["python"] else { throw CocoaError(.fileReadCorruptFile) }
            func path(_ value: String) -> URL {
                value.hasPrefix("/") ? URL(fileURLWithPath: value) : config.deletingLastPathComponent().appendingPathComponent(value)
            }
            return try Self(project: path(projectPath), python: path(pythonPath))
        }
        guard let root else { throw ProcessorRuntimeError(.developmentRequired, "Development project 缺失。") }
        let python = environment["BANKING_PROCESSOR_PYTHON"].map { URL(fileURLWithPath: $0) } ??
            (environment["PATH"] ?? "").split(separator: ":").map {
                URL(fileURLWithPath: String($0)).appendingPathComponent("python3")
            }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
        guard let python else { throw ProcessorRuntimeError(.developmentInvalid, "Development Python 配置缺失。") }
        return try Self(project: root, python: python)
        #endif
    }

    /// Foundation may identify a standalone helper as the main bundle rather than
    /// the enclosing App. Locate that App only through an existing executable.
    static func containingApp(executable: URL?) throws -> URL? {
        guard let executable else { return nil }
        func ancestor(_ file: URL) -> URL? {
            var directory = file.deletingLastPathComponent()
            while directory.path != "/" {
                if directory.pathExtension.lowercased() == "app" {
                    // Only our two direct executable locations are App runtime
                    // entry points. Xcode's nested xctest is a host tool.
                    let relative = String(file.path.dropFirst(directory.path.count + 1))
                    if relative == "Contents/MacOS/EvidenceBrowser" || relative == "Contents/Helpers/SyncHost" {
                        return directory
                    }
                    return nil
                }
                let parent = directory.deletingLastPathComponent()
                if parent == directory { break }
                directory = parent
            }
            return nil
        }
        let lexical = executable.standardizedFileURL
        let canonical = lexical.resolvingSymlinksInPath()
        guard let root = ancestor(lexical) ?? ancestor(canonical) else { return nil }
        let attributes = try? FileManager.default.attributesOfItem(atPath: canonical.path)
        guard FileManager.default.isExecutableFile(atPath: canonical.path),
              attributes?[.type] as? FileAttributeType == .typeRegular, isInside(canonical, root: root) else {
            throw ProcessorRuntimeError(.runtimeIntegrity, "App helper executable 无效或越出 bundle。")
        }
        return canonicalAppRoot(root)
    }

    /// Resolve aliases only for the trusted executable container. Data paths
    /// retain their separate no-symlink policy. Do not standardize afterwards:
    /// Foundation can shorten a physical temporary URL to a system symlink.
    static func canonicalAppRoot(_ root: URL) -> URL {
        // Foundation also aliases the physical temporary root during resolution.
        // POSIX realpath returns the physical spelling without that rewrite.
        guard let physical = realpath(root.path, nil) else { return WorkspaceIO.lexicalURL(root) }
        defer { free(physical) }
        return URL(fileURLWithPath: String(cString: physical))
    }

    private struct Manifest: Decodable {
        struct Location: Decodable { let path: String }
        struct Python: Decodable { let path: String; let version: String }
        struct Entry: Decodable {
            let path: String; let kind: String; let size: Int64; let sha256: String; let target: String?
        }
        let runtime_version: String
        let architecture: String
        let minimum_macos: String
        let lock_sha256: String
        let python: Python
        let scripts: Location
        let bootstrap: Location
        let doctor: Location
        let helper: Location
        let defaults: Location
        let entry_scripts: [String]
        let files: [Entry]
    }

    private init(root: URL, manifestURL: URL, manifest: Manifest, digest: String) throws {
        mode = .bundled; bundleRoot = Self.canonicalAppRoot(root); self.manifestURL = manifestURL
        manifestSHA256 = digest; runtimeVersion = manifest.runtime_version
        scripts = try Self.relative(manifest.scripts.path, root: root)
        codeRoot = scripts.deletingLastPathComponent()
        python = try Self.relative(manifest.python.path, root: root)
        bootstrap = try Self.relative(manifest.bootstrap.path, root: root)
        helper = try Self.relative(manifest.helper.path, root: root)
        defaults = try Self.relative(manifest.defaults.path, root: root)
    }

    private static func bundled(root: URL, manifest: URL) throws -> Self {
        do {
            let data = try Data(contentsOf: manifest)
            let decoded = try JSONDecoder().decode(Manifest.self, from: data)
            try verify(decoded, root: root)
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            return try Self(root: root, manifestURL: manifest, manifest: decoded, digest: digest)
        } catch let error as ProcessorRuntimeError { throw error }
        catch { throw ProcessorRuntimeError(.manifestInvalid, "Runtime manifest 无效：" + error.localizedDescription) }
    }

    /// Recheck before creating operation files so changed code fails before ledger mutation.
    public func validateIntegrity() throws {
        guard let root = bundleRoot, let manifestURL, let manifestSHA256 else { return }
        do {
            let data = try Data(contentsOf: manifestURL)
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard digest == manifestSHA256 else {
                throw ProcessorRuntimeError(.runtimeIntegrity, "Runtime manifest 已改变，请重新安装完整应用。")
            }
            try Self.verify(JSONDecoder().decode(Manifest.self, from: data), root: root)
        } catch let error as ProcessorRuntimeError { throw error }
        catch { throw ProcessorRuntimeError(.runtimeIntegrity, "Runtime 完整性检查失败：" + error.localizedDescription) }
    }

    static func isInside(_ url: URL, root: URL) -> Bool {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        let base = root.standardizedFileURL.resolvingSymlinksInPath().path
        return path == base || path.hasPrefix(base + "/")
    }
    private static func relative(_ path: String, root: URL) throws -> URL {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"),
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }), parts.first == "Contents" else {
            throw ProcessorRuntimeError(.manifestInvalid, "Runtime manifest 含无效相对路径：" + path)
        }
        let url = URL(fileURLWithPath: root.path + "/" + path)
        guard isInside(url, root: root) else {
            throw ProcessorRuntimeError(.manifestInvalid, "Runtime 路径越出 App bundle：" + path)
        }
        return url
    }
    private static func hash(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var digest = SHA256()
        while let data = try file.read(upToCount: 1024 * 1024), !data.isEmpty { digest.update(data: data) }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
    private static func validHash(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    private static func verify(_ manifest: Manifest, root: URL) throws {
        guard !manifest.runtime_version.isEmpty,
              manifest.architecture == "arm64", manifest.minimum_macos == "14.0",
              !manifest.python.version.isEmpty, validHash(manifest.lock_sha256), !manifest.files.isEmpty, manifest.files.count <= 50_000,
              Set(manifest.entry_scripts).count == manifest.entry_scripts.count,
              ["app_review.py", "import_review_materials.py", "runtime_doctor.py"].allSatisfy(manifest.entry_scripts.contains)
        else { throw ProcessorRuntimeError(.manifestInvalid, "Runtime manifest contract 不受支持。") }
        let paths = manifest.files.map(\.path)
        guard Set(paths).count == paths.count else { throw ProcessorRuntimeError(.manifestInvalid, "Runtime manifest 有重复文件。") }
        let required = [manifest.python.path, manifest.helper.path, manifest.bootstrap.path, manifest.doctor.path,
                        manifest.defaults.path + "/default-config.json"] +
            manifest.entry_scripts.map { manifest.scripts.path + "/" + $0 }
        guard required.allSatisfy(Set(paths).contains), manifest.entry_scripts.allSatisfy({ !$0.contains("/") && $0.hasSuffix(".py") }) else {
            throw ProcessorRuntimeError(.manifestInvalid, "Runtime manifest 缺少必需文件。")
        }
        var isDirectory: ObjCBool = false
        let scripts = try relative(manifest.scripts.path, root: root)
        guard FileManager.default.fileExists(atPath: scripts.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ProcessorRuntimeError(.runtimeIntegrity, "Bundle processor scripts 缺失。")
        }
        for entry in manifest.files {
            let file = try relative(entry.path, root: root)
            guard entry.size >= 0, validHash(entry.sha256), ["file", "macho", "symlink"].contains(entry.kind) else {
                throw ProcessorRuntimeError(.manifestInvalid, "Runtime file metadata 无效：" + entry.path)
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            let checksum: String
            if entry.kind == "symlink" {
                guard attributes[.type] as? FileAttributeType == .typeSymbolicLink,
                      let target = entry.target, !target.hasPrefix("/"),
                      try FileManager.default.destinationOfSymbolicLink(atPath: file.path) == target,
                      entry.size == Int64(target.utf8.count) else {
                    throw ProcessorRuntimeError(.runtimeIntegrity, "Runtime symlink 已改变：" + entry.path)
                }
                checksum = SHA256.hash(data: Data(target.utf8)).map { String(format: "%02x", $0) }.joined()
            } else {
                guard attributes[.type] as? FileAttributeType == .typeRegular,
                      (attributes[.size] as? NSNumber)?.int64Value == entry.size else {
                    throw ProcessorRuntimeError(.runtimeIntegrity, "Runtime 文件类型或大小已改变：" + entry.path)
                }
                checksum = try hash(file)
            }
            guard checksum == entry.sha256 else { throw ProcessorRuntimeError(.runtimeIntegrity, "Runtime 文件 hash 不符：" + entry.path) }
        }
        for path in [manifest.python.path, manifest.helper.path] {
            guard FileManager.default.isExecutableFile(atPath: try relative(path, root: root).path) else {
                throw ProcessorRuntimeError(.runtimeIntegrity, "Bundle executable 缺失执行权限：" + path)
            }
        }
        // An omitted/injected importable file is as invalid as a changed file.
        let known = Set(paths)
        let runtime = try relative(manifest.python.path, root: root).deletingLastPathComponent().deletingLastPathComponent()
        let defaults = try relative(manifest.defaults.path, root: root)
        for directory in [scripts, runtime, defaults] {
            guard let enumeration = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
                throw ProcessorRuntimeError(.runtimeIntegrity, "Runtime 文件清单无法读取。")
            }
            var count = 0
            for case let file as URL in enumeration {
                count += 1
                guard count <= 100_000 else { throw ProcessorRuntimeError(.runtimeIntegrity, "Runtime 文件清单超出限制。") }
                let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                if values.isRegularFile == true || values.isSymbolicLink == true {
                    let prefix = root.standardizedFileURL.path + "/"
                    let path = file.standardizedFileURL.path
                    guard path.hasPrefix(prefix), known.contains(String(path.dropFirst(prefix.count))) else {
                        throw ProcessorRuntimeError(.runtimeIntegrity, "Runtime 含未登记文件，请重新安装完整应用。")
                    }
                }
            }
        }
    }
}
#endif
