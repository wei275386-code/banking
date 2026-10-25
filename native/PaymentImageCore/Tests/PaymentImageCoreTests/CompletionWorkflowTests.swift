import XCTest
@testable import PaymentImageCore

final class CompletionWorkflowTests: XCTestCase {
    func testVersionedAndUnversionedDocumentsShareCaptureContract() throws {
        let root = try TestPlatform.temporaryDirectory().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for version in ["", ",\"schemaVersion\":1"] {
            let bytes = Data("{\"datasetID\":\"audit\",\"deferred\":[\"one\"]\(version),\"metadata\":{\"retained\":true}}".utf8)
            let file = root.appendingPathComponent("completion-workflow.json")
            try bytes.write(to: file)
            XCTAssertEqual(try CompletionWorkflow.decode(bytes).deferred, ["one"])
            XCTAssertEqual(try ReviewFieldDocuments.capture(review: root)["deferred/one"], "true")
            XCTAssertEqual(try Data(contentsOf: file), bytes)
        }
    }

    func testMalformedAndUnsupportedDocumentsRejectedByDecoderAndCapture() throws {
        let root = try TestPlatform.temporaryDirectory().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let variants = ["broken", "[]", "{}", #"{"deferred":[]}"#,
            #"{"datasetID":"","deferred":[]}"#,
            #"{"datasetID":"audit","deferred":["one","one"]}"#,
            #"{"datasetID":"audit","deferred":[""]}"#,
            #"{"datasetID":"audit","deferred":99}"#,
            #"{"datasetID":"audit","deferred":[],"unknown":1}"#] +
            ["2", "0", "true", "null", #""1""#].map {
                "{\"datasetID\":\"audit\",\"deferred\":[],\"schemaVersion\":\($0)}"
            }
        for raw in variants {
            let bytes = Data(raw.utf8), file = root.appendingPathComponent("completion-workflow.json")
            try bytes.write(to: file)
            XCTAssertThrowsError(try CompletionWorkflow.decode(bytes), raw)
            XCTAssertThrowsError(try ReviewFieldDocuments.capture(review: root), raw)
            XCTAssertEqual(try Data(contentsOf: file), bytes)
        }
    }
}
