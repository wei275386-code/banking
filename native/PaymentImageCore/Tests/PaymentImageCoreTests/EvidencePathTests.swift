import Foundation
import XCTest
@testable import PaymentImageCore

final class EvidencePathTests: XCTestCase {
    func testNormalMaterialResolvesAndTraversalIsRejected() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(try EvidencePath.resolve("materials/record.json", root: root).lastPathComponent, "record.json")
        XCTAssertThrowsError(try EvidencePath.resolve("../outside.json", root: root))
        XCTAssertThrowsError(try EvidencePath.resolve(root.deletingLastPathComponent().appendingPathComponent("outside.json").path, root: root))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: root.deletingLastPathComponent())
        XCTAssertThrowsError(try EvidencePath.resolve("escape/outside.json", root: root))
    }
    func testSystemTemporaryEvidenceKeepsPhysicalSpellingForStrictHashing() throws {
        let root = try TestPlatform.temporaryDirectory().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("receipt.json"), raw = Data("{}".utf8)
        try raw.write(to: file)
        let resolved = try EvidencePath.resolve("receipt.json", root: root)
        try WorkspaceIO.rejectSymlinks(resolved)
        XCTAssertEqual(try WorkspaceIO.hash(resolved), WorkspaceIO.digest(raw))
    }

    func testInternalLinksAndMissingFilesStayInsidePhysicalRoot() throws {
        let root = try TestPlatform.temporaryDirectory().appendingPathComponent(UUID().uuidString)
        let materials = root.appendingPathComponent("materials")
        try FileManager.default.createDirectory(at: materials, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("alias"), withDestinationURL: materials)
        let direct = try EvidencePath.resolve("materials/missing.json", root: root)
        XCTAssertEqual(try EvidencePath.resolve("alias/missing.json", root: root), direct)
        try WorkspaceIO.rejectSymlinks(direct)
        let outside = root.deletingLastPathComponent().appendingPathComponent("absent-" + UUID().uuidString)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: outside)
        XCTAssertThrowsError(try EvidencePath.resolve("escape/missing.json", root: root))
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("loop").path, withDestinationPath: "absent/../loop")
        XCTAssertThrowsError(try EvidencePath.resolve("loop/missing.json", root: root))
    }

}
