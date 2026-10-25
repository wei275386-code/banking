import XCTest
import Foundation
@testable import PaymentImageCore

final class MobileBootstrapPolicyTests: XCTestCase {
    private func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("mobile-bootstrap-" + UUID().uuidString) }
    func testFreshPhoneStaysUnboundAndCreatesNoHostOrReports() throws {
        let folder = root(); defer { try? FileManager.default.removeItem(at: folder) }
        XCTAssertEqual(try MobileBootstrapPolicy.source(at: folder), .awaitingCheckpoint)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let outbox = folder.appendingPathComponent("processing-outbox")
        try FileManager.default.createDirectory(at: outbox, withIntermediateDirectories: true)
        try Data("saved offline input".utf8).write(to: outbox.appendingPathComponent("retained.mov"))
        let before = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertEqual(try MobileBootstrapPolicy.source(at: folder), .awaitingCheckpoint)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), before)
        XCTAssertEqual(try Data(contentsOf: outbox.appendingPathComponent("retained.mov")), Data("saved offline input".utf8))
    }
    func testExistingLocalCopyIsRetainedWithoutSeedOrBinding() throws {
        let folder = root(); defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["financial-review.json", "payment-evidence.json"] { try Data("{}".utf8).write(to: folder.appendingPathComponent(name)) }
        XCTAssertEqual(try MobileBootstrapPolicy.source(at: folder), .localCopy(folder))
        XCTAssertEqual(try MobileBootstrapPolicy.source(at: folder).localReview, folder)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: folder.path)), Set(["financial-review.json", "payment-evidence.json"]))
    }
    func testPartialOrLinkedCopyFailsExplicitly() throws {
        let folder = root(); defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: folder.appendingPathComponent("financial-review.json"))
        XCTAssertThrowsError(try MobileBootstrapPolicy.source(at: folder))
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("payment-evidence.json"), withDestinationURL: folder.appendingPathComponent("financial-review.json"))
        XCTAssertThrowsError(try MobileBootstrapPolicy.source(at: folder))
    }
}
