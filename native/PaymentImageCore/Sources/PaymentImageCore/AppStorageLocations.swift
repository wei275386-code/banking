import Foundation
import CryptoKit
import Darwin

/// Installation-local roots. Resolving URLs never creates or migrates a ledger.
/// Only OS-owned base aliases may be resolved; selected data paths stay strict.
public struct AppStorageLocations: Sendable, Equatable {
    public enum Domain: Sendable, Equatable {
        case production
        case qa(String)
    }
    public let support: URL
    public let caches: URL
    public let temporary: URL
    public let domain: Domain
    public var workspaces: URL { support.appendingPathComponent("Workspaces", isDirectory: true) }
    public var installationIndex: URL { support.appendingPathComponent("installation-index.json") }
    public var preferencesSuiteName: String? {
        if case .qa(let name) = domain { return "FamilyReview.QA." + name }
        return nil
    }

    public init(applicationSupport: URL, caches: URL, temporary: URL, domain: Domain = .production) throws {
        let relative: String
        switch domain {
        case .production: relative = "FamilyReview"
        case .qa(let name):
            try Self.component(name)
            relative = "FamilyReviewQA/" + name
        }
        for base in [applicationSupport, caches, temporary] {
            guard base.isFileURL, !base.pathComponents.contains("..") else { throw WorkspaceError.invalid("storage base") }
            try WorkspaceIO.rejectSymlinks(base)
        }
        self.support = applicationSupport.appendingPathComponent(relative, isDirectory: true)
        self.caches = caches.appendingPathComponent(relative, isDirectory: true)
        self.temporary = temporary.appendingPathComponent(relative, isDirectory: true)
        self.domain = domain
        for root in [self.support, self.caches, self.temporary] { try WorkspaceIO.rejectSymlinks(root) }
    }

    public static func domain(bundleIdentifier: String?) -> Domain {
        guard let id = bundleIdentifier,
              id.hasSuffix(".ReleaseQA") || id.hasSuffix(".QA") || id.contains(".qa-") else { return .production }
        let hash = SHA256.hash(data: Data(id.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return .qa("bundle-" + hash)
    }
    public static var launchDomain: Domain {
        let bundled = domain(bundleIdentifier: Bundle.main.bundleIdentifier)
        if bundled != .production { return bundled }
        #if DEBUG || FAMILY_REVIEW_QA
        if ProcessInfo.processInfo.arguments.contains("--qa-isolated") { return .qa("default") }
        #endif
        return .production
    }
    public static func forCurrentProcess() throws -> Self { try system(domain: launchDomain) }

    public static func system(domain: Domain = .production, fileManager: FileManager = .default) throws -> Self {
        guard let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
              let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            throw WorkspaceError.io("system storage unavailable")
        }
        return try Self(applicationSupport: physicalSystemDirectory(support),
                        caches: physicalSystemDirectory(caches),
                        temporary: physicalSystemDirectory(fileManager.temporaryDirectory), domain: domain)
    }

    /// Restrict this to values returned by OS directory discovery, never a picker.
    public static func physicalSystemDirectory(_ url: URL) throws -> URL {
        var parent = url, missing = [String]()
        while !FileManager.default.fileExists(atPath: parent.path) {
            let next = parent.deletingLastPathComponent()
            guard next != parent else { throw WorkspaceError.io("system storage ancestor unavailable") }
            missing.append(parent.lastPathComponent); parent = next
        }
        guard let value = realpath(parent.path, nil) else { throw WorkspaceError.io("system storage resolution failed") }
        defer { free(value) }
        var result = URL(fileURLWithPath: String(cString: value), isDirectory: true)
        for name in missing.reversed() { result.appendPathComponent(name, isDirectory: true) }
        return result
    }

    public func preferences() throws -> UserDefaults {
        guard let suite = preferencesSuiteName else { return .standard }
        guard let preferences = UserDefaults(suiteName: suite) else { throw WorkspaceError.io("QA preferences unavailable") }
        return preferences
    }
    public func workspaceURL(containerID: String) throws -> URL {
        try WorkspaceIO.requireUUID(containerID, field: "container_id")
        guard containerID == containerID.lowercased() else { throw WorkspaceError.invalid("container ID normalization") }
        return try WorkspaceIO.safeChild(workspaces, containerID)
    }
    public func newWorkspaceURL() throws -> URL { try workspaceURL(containerID: UUID().uuidString.lowercased()) }
    public func cacheURL(component: String) throws -> URL {
        try Self.component(component)
        return try WorkspaceIO.safeChild(caches, component)
    }
    public func maintenanceURL() throws -> URL {
        try WorkspaceIO.safeChild(support, "maintenance/" + UUID().uuidString.lowercased())
    }
    public func managedContainerID(for url: URL) throws -> String? {
        try WorkspaceIO.rejectSymlinks(url)
        guard url.deletingLastPathComponent().path == workspaces.path else { return nil }
        let id = url.lastPathComponent
        _ = try workspaceURL(containerID: id)
        return id
    }
    private static func component(_ name: String) throws {
        guard !name.isEmpty, name.count <= 128,
              name.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }) else {
            throw WorkspaceError.invalid("storage component")
        }
    }
}

/// An index selects a location only, never a host/processor grant. Each edit is
/// locked and reloads the latest document before adding/changing the selection.
public struct AppStorageIndex: Sendable {
    public enum Shape: String, Codable, Sendable { case workspace, snapshotClient = "snapshot-client" }
    public struct Entry: Equatable, Sendable {
        public let containerID: String
        public let shape: Shape
        public let externalPath: String?
        public let bookmark: Data?
    }
    public struct Selection: Sendable {
        public let entry: Entry
        public let url: URL
        public let revision: Int64
    }
    private struct Document {
        var selected: String?
        var entries: [Entry]
        var revision: Int64
    }
    public let locations: AppStorageLocations
    private let beforeWrite: (@Sendable () throws -> Void)?
    public init(locations: AppStorageLocations) { self.locations = locations; beforeWrite = nil }
    // A deterministic boundary for lock/atomic-commit fault tests only.
    internal init(locations: AppStorageLocations, beforeWrite: @escaping @Sendable () throws -> Void) {
        self.locations = locations; self.beforeWrite = beforeWrite
    }
    public var hasRecord: Bool { FileManager.default.fileExists(atPath: locations.installationIndex.path) }

    private func document() throws -> Document {
        let file = locations.installationIndex
        try WorkspaceIO.rejectSymlinks(file)
        guard FileManager.default.fileExists(atPath: file.path) else { return Document(selected: nil, entries: [], revision: 0) }
        let raw = try WorkspaceIO.read(file, limit: 1024 * 1024), doc = try WorkspaceIO.object(raw)
        let keys: Set<String> = ["selected_container_id", "entries", "selection_revision"]
        guard Set(doc.keys) == keys, let rows = doc["entries"] as? [[String: Any]], rows.count <= 1000,
              doc["selected_container_id"] is String || doc["selected_container_id"] is NSNull else {
            throw WorkspaceError.invalid("installation index")
        }
        let revision = try WorkspaceIO.integer(raw, field: "selection_revision")
        let entries = try rows.map { row -> Entry in
            let keys = Set(row.keys)
            guard keys == ["container_id", "shape"] || keys == ["container_id", "shape", "external_path", "bookmark_base64"],
                  let id = row["container_id"] as? String,
                  let value = row["shape"] as? String, let shape = Shape(rawValue: value) else { throw WorkspaceError.invalid("installation entry") }
            try WorkspaceIO.requireUUID(id, field: "container_id")
            guard id == id.lowercased() else { throw WorkspaceError.invalid("container ID normalization") }
            let path = row["external_path"] as? String
            let bookmark: Data?
            if let path {
                guard path.hasPrefix("/"), !path.contains("\0"), !path.split(separator: "/").contains(".."),
                      let encoded = row["bookmark_base64"] as? String,
                      let data = Data(base64Encoded: encoded), !data.isEmpty else { throw WorkspaceError.invalid("external selection") }
                bookmark = data
            } else {
                guard (row["external_path"] == nil || row["external_path"] is NSNull),
                      row["bookmark_base64"] == nil || row["bookmark_base64"] is NSNull else { throw WorkspaceError.invalid("selection bookmark") }
                _ = try locations.workspaceURL(containerID: id); bookmark = nil
            }
            return Entry(containerID: id, shape: shape, externalPath: path, bookmark: bookmark)
        }
        guard Set(entries.map(\.containerID)).count == entries.count else { throw WorkspaceError.invalid("duplicate installation container") }
        let selected = doc["selected_container_id"] as? String
        guard selected == nil || entries.contains(where: { $0.containerID == selected }) else { throw WorkspaceError.invalid("missing selected container") }
        return Document(selected: selected, entries: entries, revision: revision)
    }
    public func selected() throws -> Selection? {
        let doc = try document()
        guard let id = doc.selected, let entry = doc.entries.first(where: { $0.containerID == id }) else { return nil }
        let url: URL
        if let bookmark = entry.bookmark {
            var stale = false
            // The unsandboxed Mac app and its CLI share a portable locator.
            // App-scoped resolution cannot consume another executable's bookmark.
            url = try URL(resolvingBookmarkData: bookmark, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
            guard !stale else { throw WorkspaceError.invalid("请重新选择原资料目录以恢复授权。") }
            // The caller owns the security scope and reader qualification.
        } else {
            url = try locations.workspaceURL(containerID: id)
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), directory.boolValue else {
                throw WorkspaceError.invalid("已选资料目录不可用，请恢复或重新选择已有资料。")
            }
        }
        return Selection(entry: entry, url: url, revision: doc.revision)
    }
    public func select(containerID: String, shape: Shape, repairCorrupt: Bool = false) throws {
        let url = try locations.workspaceURL(containerID: containerID)
        try requireDirectory(url)
        try edit(repairCorrupt: repairCorrupt) { doc in
            if let old = doc.entries.first(where: { $0.containerID == containerID }), old.shape != shape || old.externalPath != nil { throw WorkspaceError.invalid("container shape changed") }
            if !doc.entries.contains(where: { $0.containerID == containerID }) { doc.entries.append(Entry(containerID: containerID, shape: shape, externalPath: nil, bookmark: nil)) }
            doc.selected = containerID
        }
    }
    /// Both the external locator and its permission bookmark share one atomic
    /// selection revision. UserDefaults is not a second selection authority.
    public func selectExternal(url: URL, bookmark: Data, shape: Shape, repairCorrupt: Bool = false) throws {
        try requireDirectory(url)
        guard !bookmark.isEmpty, bookmark.count <= 512 * 1024 else { throw WorkspaceError.invalid("selection bookmark size") }
        try edit(repairCorrupt: repairCorrupt) { doc in
            let old = doc.entries.firstIndex(where: { $0.externalPath == url.path })
            let id = old.map { doc.entries[$0].containerID } ?? UUID().uuidString.lowercased()
            if let old, doc.entries[old].shape != shape { throw WorkspaceError.invalid("external container shape changed") }
            let entry = Entry(containerID: id, shape: shape, externalPath: url.path, bookmark: bookmark)
            if let old { doc.entries[old] = entry } else { doc.entries.append(entry) }
            doc.selected = id
        }
    }
    public func clearSelection() throws { try edit(repairCorrupt: false) { $0.selected = nil } }
    private func requireDirectory(_ url: URL) throws {
        guard url.isFileURL, !url.pathComponents.contains("..") else { throw WorkspaceError.invalid("selection location") }
        try WorkspaceIO.rejectSymlinks(url)
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), directory.boolValue else { throw WorkspaceError.invalid("selected workspace missing") }
    }
    private func edit(repairCorrupt: Bool, _ body: (inout Document) throws -> Void) throws {
        try WorkspaceIO.rejectSymlinks(locations.support)
        try FileManager.default.createDirectory(at: locations.support, withIntermediateDirectories: true)
        let lock = try WorkspaceIO.safeChild(locations.support, "installation-index.lock")
        let descriptor = open(lock.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard descriptor >= 0 else { throw WorkspaceError.io("installation lock") }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { throw WorkspaceError.invalid("installation lock type") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw WorkspaceError.busy }
        defer { _ = flock(descriptor, LOCK_UN) }
        var doc: Document
        do { doc = try document() }
        catch WorkspaceError.unsupportedVersion(let detail) { throw WorkspaceError.unsupportedVersion(detail) }
        catch {
            guard repairCorrupt else { throw error }
            // Explicit recovery only, after the UI validates the selected data.
            // Safe read refuses links/special files and oversized evidence.
            let damaged = try WorkspaceIO.read(locations.installationIndex, limit: 1024 * 1024)
            let hash = WorkspaceIO.digest(damaged)
            let retained = try WorkspaceIO.safeChild(locations.support, "index-recovery/" + hash + ".json")
            if FileManager.default.fileExists(atPath: retained.path) {
                guard try WorkspaceIO.read(retained) == damaged else { throw WorkspaceError.invalid("index recovery collision") }
            } else { try WorkspaceIO.atomicWrite(damaged, to: retained) }
            doc = Document(selected: nil, entries: [], revision: 0)
        }
        try body(&doc)
        guard doc.entries.count <= 1000, doc.revision < Int64.max else { throw WorkspaceError.invalid("installation index limit") }
        doc.revision += 1
        let rows: [[String: Any]] = doc.entries.sorted { $0.containerID < $1.containerID }.map {
            ["container_id": $0.containerID, "shape": $0.shape.rawValue,
             "external_path": $0.externalPath.map { $0 as Any } ?? NSNull(),
             "bookmark_base64": $0.bookmark.map { $0.base64EncodedString() as Any } ?? NSNull()]
        }
        let raw = try WorkspaceIO.canonical(["selection_revision": doc.revision,
                                            "selected_container_id": doc.selected.map { $0 as Any } ?? NSNull(), "entries": rows])
        guard raw.count <= 1024 * 1024 else { throw WorkspaceError.invalid("installation index limit") }
        try beforeWrite?()
        try WorkspaceIO.atomicWrite(raw, to: locations.installationIndex)
    }
}
