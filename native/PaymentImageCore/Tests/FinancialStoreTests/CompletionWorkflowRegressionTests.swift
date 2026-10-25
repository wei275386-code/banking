import XCTest
@testable import PaymentImageCore
@testable import EvidenceBrowser

@MainActor final class CompletionWorkflowRegressionTests: XCTestCase {
    func testVersionedWorkflowLoadsAndPreservesVersionAndMetadataOnEdit() async throws {
        let root = try StoreFixtures.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let dataset = try StoreFixtures.report().dataset_id
        let file = root.appendingPathComponent("completion-workflow.json")
        let bytes = try JSONSerialization.data(withJSONObject: ["datasetID": dataset, "deferred": ["one"], "schemaVersion": 1, "metadata": ["retain": true]])
        try bytes.write(to: file)
        let store = FinancialStore(); await store.loadFixture(root)
        XCTAssertNil(store.error); XCTAssertNil(store.completion.workflowError)
        XCTAssertEqual(store.completion.deferred, ["one"])
        await store.completion.setDeferred("two", value: true)
        XCTAssertEqual(store.completion.deferred, ["one", "two"])
        let saved = try Data(contentsOf: file)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: saved) as? [String: Any])
        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
        XCTAssertEqual(object["metadata"] as? [String: Bool], ["retain": true])
        XCTAssertEqual(Set(try CompletionWorkflow.decode(saved).deferred), ["one", "two"])
    }

    func testWatcherClearsErrorAfterRepairOrRemovalAndReenablesWrites() async throws {
        for remove in [false, true] {
            let root = try StoreFixtures.directory(files: ["financial-review.json", "payment-evidence.json", "preview.png"])
            defer { try? FileManager.default.removeItem(at: root) }
            let file = root.appendingPathComponent("completion-workflow.json")
            try Data("broken".utf8).write(to: file)
            let store = FinancialStore(), evidence = BrowserStore()
            await store.loadFixture(root); await evidence.load(root, finance: store.report)
            XCTAssertNil(store.error); XCTAssertNil(evidence.error)
            XCTAssertNotNil(store.completion.workflowError)
            if remove { try FileManager.default.removeItem(at: file) }
            else {
                let value = CompletionWorkflow(datasetID: try XCTUnwrap(store.report?.dataset_id), deferred: ["one"])
                try JSONEncoder().encode(value).write(to: file)
            }
            let refreshed = await store.refreshLocalFilesIfNeeded(evidence)
            XCTAssertTrue(refreshed, store.error ?? "")
            XCTAssertNil(store.completion.workflowError)
            XCTAssertEqual(store.completion.deferred, remove ? [] : ["one"])
            await store.completion.setDeferred("two", value: true)
            XCTAssertTrue(try CompletionWorkflow.decode(Data(contentsOf: file)).deferred.contains("two"))
        }
    }

    func testExplicitReloadClearsWorkflowErrorWithoutSwitchingWorkspace() async throws {
        let root = try StoreFixtures.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("completion-workflow.json")
        try Data("broken".utf8).write(to: file)
        let store = FinancialStore(); await store.loadFixture(root)
        XCTAssertNotNil(store.completion.workflowError)
        let value = CompletionWorkflow(datasetID: try XCTUnwrap(store.report?.dataset_id), deferred: ["one"])
        try JSONEncoder().encode(value).write(to: file)
        await store.loadFixture(root)
        XCTAssertNil(store.error); XCTAssertNil(store.completion.workflowError)
        XCTAssertEqual(store.completion.deferred, ["one"])
    }

    func testInvalidIDsBlockEditorWithoutChangingSource() async throws {
        let root = try StoreFixtures.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("completion-workflow.json")
        for ids in [["one", "one"], [""]] {
            let bytes = try JSONSerialization.data(withJSONObject: ["datasetID": "audit", "deferred": ids])
            try bytes.write(to: file)
            let workspace = CompletionWorkspace(); workspace.resetContext(folder: root, datasetID: "audit")
            XCTAssertNotNil(workspace.workflowError)
            await workspace.setDeferred("two", value: true)
            XCTAssertEqual(try Data(contentsOf: file), bytes)
        }
    }
}
