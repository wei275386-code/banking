import XCTest
@testable import PaymentImageCore

final class FinancialEffectiveProjectionTests: XCTestCase {
    private var testTemporaryDirectory: URL {
        let temporary = FileManager.default.temporaryDirectory
        return temporary.path.hasPrefix("/var/")
            ? URL(fileURLWithPath: "/private" + temporary.path, isDirectory: true)
            : temporary
    }

    func testConfirmedOutcomeRetainsDraftAndYieldsToLaterEdits() throws {
        let raw = Data(#"{"records":[{"id":"record-a","unknown":9007199254740993,"components":[{"id":"component-a","title":"Synthetic purchase","gross_cents":100,"refund_cents":0,"net_cents":100,"reason":"","primary":"Food","secondary":"Renamed coffee","included":false,"confirmed_outcome":{"override_values":{"component-a":null},"fields":{"included":true,"secondary":"Renamed coffee","classification_basis":"old rule output","completion_confirmation":{"draft":{"primary":"Food","secondary":"Original coffee","recurrence":"unconfirmed","tags":[]},"origin":"linked","sourceID":"original-source"}}}}]}]}"#.utf8)
        let restored = try FinancialEffectiveProjection.preservingConfirmedOutcomes(raw: raw, overrideValues: [:])
        let rows = try XCTUnwrap(ReleaseCanonicalJSON.canonicalArrayElements(raw: restored, atObjectKeys: ["records"]))
        XCTAssertEqual(try ReleaseCanonicalJSON.canonicalFragment(raw: rows[0], atObjectKeys: ["unknown"]), Data("9007199254740993".utf8))
        let component = try XCTUnwrap(ReleaseCanonicalJSON.canonicalArrayElements(raw: rows[0], atObjectKeys: ["components"])?.first)
        XCTAssertEqual(try ReleaseCanonicalJSON.canonicalFragment(raw: component, atObjectKeys: ["completion_confirmation", "draft", "secondary"]), Data(#""Original coffee""#.utf8))
        XCTAssertEqual(try ReleaseCanonicalJSON.canonicalFragment(raw: component, atObjectKeys: ["completion_confirmation", "origin"]), Data(#""linked""#.utf8))
        XCTAssertEqual(try ReleaseCanonicalJSON.canonicalFragment(raw: component, atObjectKeys: ["secondary"]), Data(#""Renamed coffee""#.utf8))
        let model = try JSONDecoder().decode(FinancialComponent.self, from: component)
        XCTAssertFalse(model.completionConfirmed)
        XCTAssertEqual(model.completion_confirmation?.draft.secondary, "Original coffee")
        XCTAssertEqual(try ReleaseCanonicalJSON.canonicalFragment(raw: component, atObjectKeys: ["included"]), Data("false".utf8))
        let renamed = Data(String(decoding: raw, as: UTF8.self).replacingOccurrences(of: #""secondary":"Renamed coffee","included""#, with: #""secondary":"Latest coffee","included""#).utf8)
        let afterRename = try FinancialEffectiveProjection.preservingConfirmedOutcomes(raw: renamed, overrideValues: [:], catalogSHA256: "changed")
        let renamedRecord = try XCTUnwrap(ReleaseCanonicalJSON.canonicalArrayElements(raw: afterRename, atObjectKeys: ["records"])?.first)
        let renamedComponent = try XCTUnwrap(ReleaseCanonicalJSON.canonicalArrayElements(raw: renamedRecord, atObjectKeys: ["components"])?.first)
        XCTAssertEqual(try ReleaseCanonicalJSON.canonicalFragment(raw: renamedComponent, atObjectKeys: ["secondary"]), Data(#""Latest coffee""#.utf8))
        XCTAssertEqual(try ReleaseCanonicalJSON.canonicalFragment(raw: renamedComponent, atObjectKeys: ["completion_confirmation", "draft", "secondary"]), Data(#""Original coffee""#.utf8))
        XCTAssertEqual(try FinancialEffectiveProjection.preservingConfirmedOutcomes(raw: raw, overrideValues: ["component-a": ["primary": "New"]]), raw)
        let forbidden = Data(String(decoding: raw, as: UTF8.self).replacingOccurrences(of: "classification_basis", with: "gross_cents").utf8)
        XCTAssertThrowsError(try FinancialEffectiveProjection.preservingConfirmedOutcomes(raw: forbidden, overrideValues: [:]))
    }

    func testTypedChangesPreserveUnknownValuesAndStableArrayMembers() throws {
        let raw = Data(#"{"records":[{"id":"a","value":1,"unknown":9007199254740993},{"id":"b","value":2,"decimal":1.0}],"unmodeled":{"e\u0301":-0.0,"é":1e100}}"#.utf8)
        let before = Data(#"{"records":[{"id":"a","value":1},{"id":"b","value":2}]}"#.utf8)
        let after = Data(#"{"records":[{"id":"b","value":3},{"id":"a","value":1}]}"#.utf8)
        let result = try ReleaseCanonicalJSON.applyingModelChanges(raw: raw, before: before, after: after)
        let expected = Data(#"{"records":[{"id":"b","value":3,"decimal":1.0},{"id":"a","value":1,"unknown":9007199254740993}],"unmodeled":{"e\u0301":-0.0,"é":1e100}}"#.utf8)
        XCTAssertEqual(result, try ReleaseCanonicalJSON.canonicalize(raw: expected))
        XCTAssertThrowsError(try ReleaseCanonicalJSON.applyingModelChanges(raw: raw, before: before,
            after: Data(#"{"records":[{"id":"a","value":2},{"id":"a","value":3}]}"#.utf8)))
    }

    func testRecursiveFireOverlayDoesNotRoundUnexposedNumbers() throws {
        let raw = Data(#"{"salary":1.0,"unknown":{"integer":9007199254740993,"decimal":1e100},"buckets":{"enabled":false,"other":-0.0}}"#.utf8)
        let changes = Data(#"{"salary":100.0,"buckets":{"enabled":true}}"#.utf8)
        let result = try ReleaseCanonicalJSON.mergingObjects(raw: raw, changes: changes)
        XCTAssertEqual(try ReleaseCanonicalJSON.canonicalFragment(raw: result, atObjectKeys: ["unknown"]),
                       try ReleaseCanonicalJSON.canonicalFragment(raw: raw, atObjectKeys: ["unknown"]))
        XCTAssertEqual(try ReleaseCanonicalJSON.canonicalFragment(raw: result, atObjectKeys: ["buckets", "other"]), Data("-0.0".utf8))
    }

    func testUnidentifiedObjectArrayChangeCannotDiscardUnknownData() throws {
        XCTAssertThrowsError(try ReleaseCanonicalJSON.applyingModelChanges(
            raw: Data(#"{"rows":[{"name":"old","private":1e100}]}"#.utf8),
            before: Data(#"{"rows":[{"name":"old"}]}"#.utf8),
            after: Data(#"{"rows":[{"name":"new"}]}"#.utf8)))
    }

    func testTaxonomyRenameReorderAndSQLiteOnlyCatalogRemainLossless() throws {
        let source = try XCTUnwrap(Bundle.module.url(forResource: "financial-review", withExtension: "json", subdirectory: "Fixtures/current"))
        let review = testTemporaryDirectory.appendingPathComponent("effective-catalog-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: review, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: review) }
        var raw = try Data(contentsOf: source)
        var rows = try XCTUnwrap(ReleaseCanonicalJSON.canonicalArrayElements(raw: raw, atObjectKeys: ["taxonomy"]))
        let model = try JSONDecoder().decode(FinancialReport.self, from: raw)
        let old = try XCTUnwrap(model.taxonomy.first(where: { $0.primary != "待分类" && !$0.secondaries.isEmpty }))
        let index = try XCTUnwrap(model.taxonomy.firstIndex(where: { $0.primary == old.primary }))
        rows[index] = try ReleaseCanonicalJSON.replacingObjectMember(raw: rows[index], key: "private", valueRaw: Data("0.12345678901234567890123456789".utf8))
        raw = try ReleaseCanonicalJSON.replacingObjectMember(raw: raw, key: "taxonomy", valueRaw: Data(("[" + rows.map { String(decoding: $0, as: UTF8.self) }.joined(separator: ",") + "]").utf8))
        try raw.write(to: review.appendingPathComponent("financial-review.json"))
        let original = try CategoryCatalogFile.load(root: review, taxonomy: model.taxonomy, records: model.records)
        var updated = original
        let id = try XCTUnwrap(updated.primaries.first(where: { $0.name == old.primary })?.id)
        try updated.renamePrimary(id: id, name: "重命名分类")
        updated.primaries.reverse()
        try CategoryCatalogFile.save(updated, root: review, expected: original)
        try FileManager.default.removeItem(at: review.appendingPathComponent("category-catalog.json"))
        let dbBefore = try Data(contentsOf: review.appendingPathComponent("financial-review.sqlite3"))
        let contentsBefore = try FileManager.default.contentsOfDirectory(atPath: review.path).sorted()
        let result = try FinancialEffectiveProjection.read(review: review)
        let effective = try JSONDecoder().decode(FinancialReport.self, from: result)
        XCTAssertEqual(effective.taxonomy.map(\.primary), updated.taxonomy.map(\.primary))
        let renamed = try XCTUnwrap(ReleaseCanonicalJSON.canonicalArrayElements(raw: result, atObjectKeys: ["taxonomy"])?.first { bytes in
            (try? ReleaseCanonicalJSON.canonicalFragment(raw: bytes, atObjectKeys: ["primary"])) == Data("\"重命名分类\"".utf8)
        })
        XCTAssertEqual(try ReleaseCanonicalJSON.canonicalFragment(raw: renamed, atObjectKeys: ["private"]), Data("0.12345678901234567890123456789".utf8))
        XCTAssertEqual(try Data(contentsOf: review.appendingPathComponent("financial-review.sqlite3")), dbBefore)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: review.path).sorted(), contentsBefore)
    }

    func testOverrideDuplicateAndCanonicallyEquivalentKeysAreRejected() throws {
        let source = try XCTUnwrap(Bundle.module.url(forResource: "financial-review", withExtension: "json", subdirectory: "Fixtures/current"))
        let review = testTemporaryDirectory.appendingPathComponent("effective-duplicate-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: review, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: review) }
        try Data(contentsOf: source).write(to: review.appendingPathComponent("financial-review.json"))
        for overrides in [#"{"a":{},"a":{}}"#, #"{"e\u0301":{},"é":{}}"#, #"{"":{}}"#] {
            try Data(overrides.utf8).write(to: review.appendingPathComponent("review-overrides.json"))
            XCTAssertThrowsError(try FinancialEffectiveProjection.read(review: review))
        }
    }

    func testGlobalComponentCanonicalAliasCannotEditTwoDifferentRecords() throws {
        let source = try XCTUnwrap(Bundle.module.url(forResource: "financial-review", withExtension: "json", subdirectory: "Fixtures/current"))
        let review = testTemporaryDirectory.appendingPathComponent("effective-owner-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: review, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: review) }
        let raw = try Data(contentsOf: source)
        let record = try XCTUnwrap(ReleaseCanonicalJSON.canonicalArrayElements(raw: raw, atObjectKeys: ["records"])?.first)
        let component = try XCTUnwrap(ReleaseCanonicalJSON.canonicalArrayElements(raw: record, atObjectKeys: ["components"])?.first)
        var copies: [Data] = []
        for (offset, spelling) in ["é", "e\u{0301}"].enumerated() {
            let changed = try ReleaseCanonicalJSON.replacingObjectMember(raw: component, key: "id", valueRaw: JSONEncoder().encode(spelling))
            var copy = try ReleaseCanonicalJSON.replacingObjectMember(raw: record, key: "id", valueRaw: JSONEncoder().encode("owner-\(offset)"))
            copy = try ReleaseCanonicalJSON.replacingObjectMember(raw: copy, key: "components", valueRaw: Data(("[" + String(decoding: changed, as: UTF8.self) + "]").utf8))
            copies.append(copy)
        }
        let rows = Data(("[" + copies.map { String(decoding: $0, as: UTF8.self) }.joined(separator: ",") + "]").utf8)
        try ReleaseCanonicalJSON.replacingObjectMember(raw: raw, key: "records", valueRaw: rows).write(to: review.appendingPathComponent("financial-review.json"))
        XCTAssertThrowsError(try FinancialEffectiveProjection.read(review: review))
    }

    func testUnknownCategoryWithoutProvenRenameIdentityFailsClosed() throws {
        let source = try XCTUnwrap(Bundle.module.url(forResource: "financial-review", withExtension: "json", subdirectory: "Fixtures/current"))
        let review = testTemporaryDirectory.appendingPathComponent("effective-empty-category-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: review, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: review) }
        let bytes = try ReleaseCanonicalJSON.replacingObjectMember(raw: Data(contentsOf: source), key: "taxonomy",
            valueRaw: Data(#"[{"primary":"空分类","secondaries":[],"private":1e100}]"#.utf8))
        try bytes.write(to: review.appendingPathComponent("financial-review.json"))
        let report = try JSONDecoder().decode(FinancialReport.self, from: bytes)
        let catalog = try CategoryCatalogFile.load(root: review, taxonomy: report.taxonomy, records: report.records)
        var renamed = catalog
        try renamed.renamePrimary(id: XCTUnwrap(renamed.primaries.first { $0.name == "空分类" }?.id), name: "新空分类")
        try CategoryCatalogFile.save(renamed, root: review, expected: catalog)
        XCTAssertThrowsError(try FinancialEffectiveProjection.read(review: review))
        XCTAssertEqual(try Data(contentsOf: review.appendingPathComponent("financial-review.json")), bytes)
    }

    func testSourceGroupMoveRetainsUnknownDataAndCurrentRecordWinsOverArchive() throws {
        let source = try XCTUnwrap(Bundle.module.url(forResource: "financial-review", withExtension: "json", subdirectory: "Fixtures/current"))
        let review = testTemporaryDirectory.appendingPathComponent("effective-source-group-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: review, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: review) }
        var raw = try Data(contentsOf: source)
        let record = try XCTUnwrap(ReleaseCanonicalJSON.canonicalArrayElements(raw: raw, atObjectKeys: ["records"])?.first)
        let archived = try ReleaseCanonicalJSON.replacingObjectMember(raw: record, key: "title", valueRaw: JSONEncoder().encode("旧档案标题"))
        let group = Data((#"{"id":"group-one","origin":"confirmed","fingerprint":"synthetic-scope","retained_ids":[],"shadow_ids":[],"status":"confirmed","can_confirm":false,"private":9007199254740993,"shadow_records":["#
            + String(decoding: archived, as: UTF8.self) + "]}").utf8)
        raw = try ReleaseCanonicalJSON.replacingObjectMember(raw: raw, key: "source_record_sets", valueRaw: Data(("[" + String(decoding: group, as: UTF8.self) + "]").utf8))
        try raw.write(to: review.appendingPathComponent("financial-review.json"))
        let effective = try FinancialEffectiveProjection.read(review: review)
        let model = try JSONDecoder().decode(FinancialReport.self, from: effective)
        XCTAssertEqual(model.records.first?.title, try JSONDecoder().decode(FinancialLifecycle.self, from: record).title)
        let moved = try XCTUnwrap(ReleaseCanonicalJSON.canonicalArrayElements(raw: effective, atObjectKeys: ["source_record_set_candidates"])?.first)
        XCTAssertEqual(try ReleaseCanonicalJSON.canonicalFragment(raw: moved, atObjectKeys: ["private"]), Data("9007199254740993".utf8))
        XCTAssertEqual(try Data(contentsOf: review.appendingPathComponent("financial-review.json")), raw)
    }

    func testEffectiveReaderAppliesProductDecisionsWithoutWritingSources() throws {
        let source = try XCTUnwrap(Bundle.module.url(forResource: "financial-review", withExtension: "json", subdirectory: "Fixtures/current"))
        let review = testTemporaryDirectory.appendingPathComponent("effective-read-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: review, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: review) }
        var raw = try Data(contentsOf: source)
        raw = try ReleaseCanonicalJSON.replacingObjectMember(raw: raw, key: "private_unknown", valueRaw: Data("9007199254740993".utf8))
        try raw.write(to: review.appendingPathComponent("financial-review.json"))
        let user = Data(#"{"afterTaxSalary":12345.0,"unknown_private":{"decimal":1e100}}"#.utf8)
        try user.write(to: review.appendingPathComponent("fire-parameters-user.json"))
        let before = try FileManager.default.contentsOfDirectory(atPath: review.path)
        let effective = try FinancialEffectiveProjection.read(review: review)
        XCTAssertEqual(try JSONDecoder().decode(FinancialReport.self, from: effective).fire_parameters.afterTaxSalary, 12345)
        XCTAssertEqual(try ReleaseCanonicalJSON.canonicalFragment(raw: effective, atObjectKeys: ["private_unknown"]), Data("9007199254740993".utf8))
        XCTAssertEqual(try ReleaseCanonicalJSON.canonicalFragment(raw: effective, atObjectKeys: ["fire_parameters", "unknown_private"]),
                       try ReleaseCanonicalJSON.canonicalFragment(raw: user, atObjectKeys: ["unknown_private"]))
        XCTAssertEqual(try Data(contentsOf: review.appendingPathComponent("financial-review.json")), raw)
        XCTAssertEqual(try Data(contentsOf: review.appendingPathComponent("fire-parameters-user.json")), user)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: review.path), before)
    }
}
