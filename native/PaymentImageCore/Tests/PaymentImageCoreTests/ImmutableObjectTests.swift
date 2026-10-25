import Foundation
import XCTest
@testable import PaymentImageCore

final class ImmutableObjectTests: XCTestCase {
    func testImmutableMetadataPreservesBytesAndHashObjectRepairsOnlyExactContent() throws {
        let root = try TestPlatform.temporaryDirectory().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data("{ \"amount\": 42, \"metadata\": {\"note\": \"synthetic\"} }".utf8)
        let destination = root.appendingPathComponent("immutable.json")
        try ReviewSyncIO.immutable(bytes, at: destination)
        try ReviewSyncIO.immutable(WorkspaceIO.canonical(WorkspaceIO.object(bytes)), at: destination)
        XCTAssertEqual(try WorkspaceIO.read(destination), bytes)
        XCTAssertThrowsError(try ReviewSyncIO.immutable(Data("{}".utf8), at: destination))
        let addressed = root.appendingPathComponent(WorkspaceIO.digest(bytes))
        try WorkspaceIO.atomicWrite(Data("broken bytes".utf8), to: addressed)
        try ReviewSyncIO.storeContentAddressed(bytes, at: addressed)
        XCTAssertEqual(try WorkspaceIO.read(addressed), bytes)
    }
}
