import XCTest
@testable import PaymentImageCore
@testable import EvidenceBrowser

@MainActor final class SourceRecordSetTests: XCTestCase {
    private func record(_ id: String, bank: Bool = false, refund: Bool = false) throws -> FinancialLifecycle {
        let object: [String: Any] = ["id": id, "date": "2026-03-30", "title": id, "status": "支付成立", "account_views": ["9001"], "evidence_keys": [id],
            "components": refund ? [] : [["id": id + ":item", "title": id, "gross_cents": 699, "refund_cents": 0, "net_cents": 699, "primary": "日常消费", "secondary": "餐饮", "classification_basis": "规则推断", "included": bank, "reason": bank ? "" : "来源关联待确认"]],
            "events": [["id": id, "date": "2026-03-30", "kind": refund ? "bank_credit" : bank ? "bank_debit" : "payment", "source": bank ? "bank" : "unionpay", "amount_cents": 699, "status": "原始证据"]],
            "user_relation": "self", "non_consumption": false, "unallocated_credit_cents": refund ? 699 : 0]
        return try JSONDecoder().decode(FinancialLifecycle.self, from: ReviewSyncIO.json(object))
    }
    private func group(_ retained: [FinancialLifecycle], _ shadows: [FinancialLifecycle], status: String = "candidate", fingerprint: String = "evidence-v1", origin: String = "automatic", id: String = "set1", defaultStatus: String? = nil, canConfirm: Bool = true, reasons: [String] = []) throws -> SourceRecordSet {
        let object: [String: Any] = ["id": id, "kind": "payment", "retained_ids": retained.map(\.id), "shadow_ids": shadows.map(\.id),
            "signatures": Dictionary(uniqueKeysWithValues: (retained + shadows).map { ($0.id, "backend-scope") }),
            "basis": "同账户、币种、方向、金额与完整笔数的双来源", "status": status, "evidence_keys": (retained + shadows).flatMap(\.evidence_keys),
            "retained_records": try JSONSerialization.jsonObject(with: JSONEncoder().encode(retained)),
            "shadow_records": try JSONSerialization.jsonObject(with: JSONEncoder().encode(shadows)),
            "origin": origin, "default_status": defaultStatus ?? (status == "confirmed" ? "confirmed" : "candidate"), "can_confirm": canConfirm, "reasons": reasons, "fingerprint": fingerprint, "date": "2026-03-30", "amount_cents": 699,
            "network_count": shadows.count, "bank_count": retained.count]
        return try JSONDecoder().decode(SourceRecordSet.self, from: ReviewSyncIO.json(object))
    }
    private func report(_ records: [FinancialLifecycle], group: SourceRecordSet) throws -> FinancialReport {
        var report = try StoreFixtures.report()
        report.records = records; report.account_consolidation = nil; report.refund_candidates = nil
        report.source_record_sets = group.status == "candidate" ? [] : [group]
        report.source_record_set_candidates = group.status == "candidate" ? [group] : []
        return report
    }
    private func fixture(_ report: FinancialReport) throws -> URL {
        let root = try AppStorageLocations.physicalSystemDirectory(FileManager.default.temporaryDirectory).appendingPathComponent("source-set-qa-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(report).write(to: root.appendingPathComponent("financial-review.json"))
        try Data("{}".utf8).write(to: root.appendingPathComponent("review-overrides.json"))
        return root
    }
    private func override(_ group: SourceRecordSet, _ disposition: SourceRecordSetDisposition) -> [String: CategoryOverride] {
        [group.reviewOverrideKey: CategoryOverride(primary: "", secondary: "", source_record_set_review: SourceRecordSetReview(fingerprint: group.fingerprint, disposition: disposition))]
    }
    func testConfirmRejectAndAutomaticRecoverArchivedMembersWithoutMutatingAnchors() throws {
        let bank = try record("bank1", bank: true), shadow = try record("network1")
        let candidate = try group([bank], [shadow])
        let base = try report([bank, shadow], group: candidate)
        var projected = base; FinancialStore.applyCompletion(override(candidate, .confirm), to: &projected)
        XCTAssertEqual(projected.records.map(\.id), [bank.id])
        XCTAssertEqual(try TransactionFacts.signature(projected.records[0]), try TransactionFacts.signature(bank))
        XCTAssertTrue(try XCTUnwrap(SourceRecordSets.groups(projected).first).confirmed)
        var confirmed = try report([bank], group: group([bank], [shadow], status: "confirmed"))
        FinancialStore.applyCompletion(override(candidate, .reject), to: &confirmed)
        XCTAssertEqual(Set(confirmed.records.map(\.id)), [bank.id, shadow.id]); XCTAssertEqual(SourceRecordSets.groups(confirmed).first?.status, "rejected")
        var automatic = base; FinancialStore.applyCompletion(override(candidate, .automatic), to: &automatic)
        XCTAssertEqual(automatic.records.count, 2); XCTAssertEqual(SourceRecordSets.groups(automatic).first?.status, "candidate")
        var legacy = try report([bank], group: group([bank], [shadow], status: "confirmed", origin: "confirmed"))
        FinancialStore.applyCompletion(override(candidate, .automatic), to: &legacy)
        XCTAssertEqual(legacy.records.map(\.id), [bank.id])
    }
    func testChangedFingerprintFactOrAssociationLeavesShadowsVisible() throws {
        let bank = try record("bank1", bank: true), shadow = try record("network1"), refund = try record("refund", bank: true, refund: true)
        let candidate = try group([bank], [shadow])
        var changed = try report([bank, shadow], group: group([bank], [shadow], fingerprint: "evidence-v2"))
        SourceRecordSets.apply(override(candidate, .confirm), to: &changed)
        XCTAssertEqual(changed.records.count, 2); XCTAssertEqual(SourceRecordSets.groups(changed).first?.status, "evidence_changed")
        var stale = try report([bank, shadow], group: candidate); stale.records[0].date = "2026-03-31"
        SourceRecordSets.apply(override(candidate, .confirm), to: &stale)
        XCTAssertEqual(stale.records.count, 2); XCTAssertTrue(SourceRecordSets.groups(stale).first?.review_reason?.contains("原始事实") == true)
        var facts = try TransactionFactReview(record: shadow); facts.amounts[shadow.components[0].id] = FactAmounts(gross: 700, refund: 0)
        var edits = override(candidate, .confirm); edits[shadow.reviewOverrideKey] = CategoryOverride(primary: "", secondary: "", transaction_facts: facts)
        var conflict = try report([bank, shadow], group: candidate); SourceRecordSets.apply(edits, to: &conflict)
        XCTAssertEqual(conflict.records.count, 2)
        var link = try TransactionFactReview(record: refund); link.disposition = .refund; link.targetID = shadow.components[0].id; link.targetSignature = try TransactionFacts.signature(shadow); link.refundCents = 699
        edits = override(candidate, .confirm); edits[refund.reviewOverrideKey] = CategoryOverride(primary: "", secondary: "", transaction_facts: link)
        conflict = try report([bank, shadow, refund], group: candidate); SourceRecordSets.apply(edits, to: &conflict)
        XCTAssertEqual(conflict.records.count, 3); XCTAssertTrue(SourceRecordSets.groups(conflict).first?.review_reason?.contains("引用") == true)
        var rejected = try report([bank, shadow], group: group([bank], [shadow], fingerprint: "evidence-v2"))
        SourceRecordSets.apply(override(candidate, .reject), to: &rejected)
        XCTAssertEqual(SourceRecordSets.groups(rejected).first?.status, "rejected")
    }
    func testRetainedRefundAppliesExactlyOnceAfterSourceProjection() throws {
        let bank = try record("bank1", bank: true), shadow = try record("network1"), refund = try record("refund", bank: true, refund: true)
        let candidate = try group([bank], [shadow])
        var link = try TransactionFactReview(record: refund); link.disposition = .refund; link.targetID = bank.components[0].id; link.targetSignature = try TransactionFacts.signature(bank); link.refundCents = 699
        var edits = override(candidate, .confirm); edits[refund.reviewOverrideKey] = CategoryOverride(primary: "", secondary: "", transaction_facts: link)
        var projected = try report([bank, shadow, refund], group: candidate)
        FinancialStore.applyCompletion(edits, to: &projected)
        XCTAssertEqual(projected.records.count, 2)
        XCTAssertEqual(projected.records.first { $0.id == bank.id }?.components[0].refund_cents, 699)
        XCTAssertEqual(FinancialMath.statistics(projected.records).net, 0)
    }
    func testAtomicWriteAndBothWayFieldSyncPreserveOtherDecisions() async throws {
        let bank = try record("bank1", bank: true), shadow = try record("network1")
        let candidate = try group([bank], [shadow]), base = try report([bank, shadow], group: candidate)
        let review = try fixture(base); defer { try? FileManager.default.removeItem(at: review) }
        let family = try await CurrentFamilyStoreFixture.make(review: review); defer { family.cleanup() }
        let saved = await family.first.saveSourceSet(try XCTUnwrap(family.first.sourceRecordGroups.first), disposition: .confirm)
        XCTAssertTrue(saved, family.first.error ?? ""); XCTAssertEqual(family.first.report?.records.count, 1)
        try await family.sync(from: family.a)
        XCTAssertEqual(family.second.report?.records.count, 1)
        try await family.edit(family.a) { root in
            let file = root.appendingPathComponent("review-overrides.json"), bytes = try Data(contentsOf: file)
            let expected = try CompletionOverrideFile.entry(candidate.reviewOverrideKey, in: bytes)
            let write = try CompletionOverrideFile.saveSourceSet(root: root, group: candidate, disposition: .reject, expected: expected)
            XCTAssertThrowsError(try CompletionOverrideFile.saveSourceSet(root: root, group: candidate, disposition: .automatic, expected: expected))
            XCTAssertEqual(try Data(contentsOf: file), write.document)
        }
        try await family.sync(from: family.a)
        let reset = await family.second.saveSourceSet(try XCTUnwrap(family.second.sourceRecordGroups.first), disposition: .automatic)
        XCTAssertTrue(reset, family.second.error ?? ""); XCTAssertEqual(family.second.report?.records.count, 2)
        let queued = try XCTUnwrap(ReviewFamilyClientSession.read(paths: family.b)).queue
        let keys = queued.flatMap { $0.revision.values.keys }
        XCTAssertTrue(keys.contains("override/source-set:set1/source_record_set_review"))
        XCTAssertFalse(keys.contains { $0.hasPrefix("override/source-set:set1/source_record_set_review/") })
        try await family.sync(from: family.b)
        XCTAssertEqual(family.first.report?.records.count, 2)
    }
    func testConcurrentDecisionsConflictAsWholeFieldsAndSavePreservesUnknownMetadata() async throws {
        let bank = try record("bank1", bank: true), shadow = try record("network1")
        let candidate = try group([bank], [shadow]), updated = try group([bank], [shadow], fingerprint: "changed-evidence")
        let base = try report([bank, shadow], group: candidate)
        let review = try fixture(base); defer { try? FileManager.default.removeItem(at: review) }
        let family = try await CurrentFamilyStoreFixture.make(review: review); defer { family.cleanup() }
        let metadata: [String: Any] = [candidate.reviewOverrideKey: ["primary": "", "secondary": "", "tags": ["保持"], "future_metadata": ["value": 42]],
            bank.components[0].id: ["primary": "日常消费", "secondary": "餐饮", "recurrence": "recurring"]]
        try await family.edit(family.a) { root in
            let original = try ReviewSyncIO.json(metadata)
            try original.write(to: root.appendingPathComponent("review-overrides.json"))
            let write = try CompletionOverrideFile.saveSourceSet(root: root, group: candidate, disposition: .confirm, expected: CompletionOverrideFile.entry(candidate.reviewOverrideKey, in: original))
            let object = try JSONSerialization.jsonObject(with: write.document) as! [String: Any]
            XCTAssertEqual((object[candidate.reviewOverrideKey] as? [String: Any])?["tags"] as? [String], ["保持"])
            XCTAssertEqual(((object[candidate.reviewOverrideKey] as? [String: Any])?["future_metadata"] as? [String: Int])?["value"], 42)
            XCTAssertEqual((object[bank.components[0].id] as? [String: Any])?["recurrence"] as? String, "recurring")
        }
        try await family.edit(family.b) { root in
            _ = try CompletionOverrideFile.saveSourceSet(root: root, group: updated, disposition: .reject, expected: nil)
        }
        try await ReviewFamilyClientSession.transfer(paths: family.a)
        try await family.sync(from: family.b)
        let key = "override/source-set:set1/source_record_set_review"
        let handle = try XCTUnwrap(ReviewFamilyClientSession.read(paths: family.b))
        let decisions = try XCTUnwrap(handle.conflicts[key]).map { try JSONDecoder().decode(SourceRecordSetReview.self, from: Data($0.utf8)) }
        XCTAssertEqual(decisions.count, 2)
        XCTAssertTrue(decisions.contains(SourceRecordSetReview(fingerprint: candidate.fingerprint, disposition: .confirm)))
        XCTAssertTrue(decisions.contains(SourceRecordSetReview(fingerprint: updated.fingerprint, disposition: .reject)))
    }
    func testOverlappingConfirmedGroupsDoNotHideEitherSource() throws {
        let bank = try record("bank1", bank: true), a = try record("network1"), b = try record("network2")
        let first = try group([bank], [a], status: "confirmed"), second = try group([bank], [b], status: "confirmed", id: "set2")
        var projected = try report([bank, a, b], group: first); projected.source_record_sets = [first, second]
        SourceRecordSets.apply([:], to: &projected)
        XCTAssertEqual(projected.records.count, 3)
        XCTAssertTrue(SourceRecordSets.groups(projected).allSatisfy { $0.status == "evidence_changed" })
    }
    func testBackendFlagsDefaultAndLocalHumanEditsProtectAutomaticProjection() throws {
        let bank = try record("bank1", bank: true), shadow = try record("network1")
        let blocked = try group([bank], [shadow], canConfirm: false, reasons: ["来源笔数不齐"])
        var projected = try report([bank, shadow], group: blocked)
        SourceRecordSets.apply(override(blocked, .confirm), to: &projected)
        XCTAssertEqual(projected.records.count, 2); XCTAssertEqual(SourceRecordSets.groups(projected).first?.review_reason, "来源笔数不齐")
        let rejectedAuto = try group([bank], [shadow], status: "rejected", defaultStatus: "confirmed")
        projected = try report([bank, shadow], group: rejectedAuto)
        SourceRecordSets.apply(override(rejectedAuto, .automatic), to: &projected)
        XCTAssertEqual(projected.records.count, 1)
        let manualCandidate = try group([bank], [shadow], status: "confirmed", origin: "manual", defaultStatus: "candidate")
        projected = try report([bank], group: manualCandidate)
        SourceRecordSets.apply(override(manualCandidate, .automatic), to: &projected)
        XCTAssertEqual(projected.records.count, 2); XCTAssertEqual(SourceRecordSets.groups(projected).first?.status, "candidate")
        let automatic = try group([bank], [shadow], status: "confirmed")
        var edits = [shadow.components[0].id: CategoryOverride(primary: "日常消费", secondary: "餐饮")]
        projected = try report([bank], group: automatic); SourceRecordSets.apply(edits, to: &projected)
        XCTAssertEqual(projected.records.count, 2); XCTAssertEqual(SourceRecordSets.groups(projected).first?.status, "candidate")
        edits.merge(override(automatic, .confirm)) { _, new in new }
        projected = try report([bank], group: automatic); SourceRecordSets.apply(edits, to: &projected)
        XCTAssertEqual(projected.records.count, 1)
        var facts = try TransactionFactReview(record: shadow); facts.userID = "manual-user"
        edits = override(automatic, .confirm); edits[shadow.reviewOverrideKey] = CategoryOverride(primary: "", secondary: "", transaction_facts: facts)
        projected = try report([bank], group: automatic); SourceRecordSets.apply(edits, to: &projected)
        XCTAssertEqual(projected.records.count, 2)
        let confirmed = try group([bank], [shadow], status: "confirmed", origin: "confirmed")
        projected = try report([bank], group: confirmed); SourceRecordSets.apply(edits, to: &projected)
        XCTAssertEqual(projected.records.count, 1)
        XCTAssertTrue(projected.source_record_sets?.allSatisfy(\.confirmed) == true)
    }
    func testUndoRestoresEditableShadowAndRemovesOnlyGroupTraceLinks() async throws {
        var bank = try record("bank1", bank: true); let shadow = try record("network1")
        let candidate = try group([bank], [shadow], status: "confirmed", origin: "confirmed")
        func trace(_ id: String, basis: String) throws -> TransactionTraceSource {
            try JSONDecoder().decode(TransactionTraceSource.self, from: ReviewSyncIO.json([
                "id": id, "association": "linked", "basis": basis, "platform": id == bank.id ? "bank" : "unionpay",
                "date": "2026-03-30", "currency": "CNY", "event_kind": "payment", "status": "原始证据", "location": "原始画面"
            ]))
        }
        let groupedBasis = candidate.basis + "；整组来源已确认，未指定逐笔配对"
        bank.trace_sources = [try trace(bank.id, basis: groupedBasis), try trace(shadow.id, basis: groupedBasis), try trace("independent", basis: "独立人工关联")]
        let base = try report([bank], group: candidate), root = try fixture(base)
        defer { try? FileManager.default.removeItem(at: root) }
        let raw = try Data(contentsOf: root.appendingPathComponent("financial-review.json"))
        let store = FinancialStore(); await store.loadFixture(root)
        XCTAssertEqual(store.baseReport?.records.count, 2)
        let undone = await store.saveSourceSet(try XCTUnwrap(store.sourceRecordGroups.first), disposition: .reject)
        XCTAssertTrue(undone, store.error ?? "")
        let retained = try XCTUnwrap(store.report?.records.first { $0.id == bank.id })
        XCTAssertEqual(retained.trace_sources?.map(\.id), [bank.id, "independent"])
        XCTAssertEqual(retained.trace_sources?.first?.basis, "交易已关联的原始证据")
        XCTAssertEqual(try TransactionFacts.signature(retained), try TransactionFacts.signature(bank))
        let restored = try XCTUnwrap(store.report?.records.first { $0.id == shadow.id })
        var review = try TransactionFactReview(record: shadow); review.userID = "manual-user"
        let saved = await store.saveFacts(try XCTUnwrap(store.beginFactEdit(restored)), review: review)
        XCTAssertTrue(saved, store.error ?? "")
        XCTAssertEqual(store.report?.records.first { $0.id == shadow.id }?.user_id, "manual-user")
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("financial-review.json")), raw)
        let expected = try CompletionOverrideFile.entry(candidate.reviewOverrideKey, in: store.overrideDocument)
        let baselineDependencies = try CompletionOverrideFile.dependencies([shadow.reviewOverrideKey], in: Data("{}".utf8))
        XCTAssertThrowsError(try CompletionOverrideFile.saveSourceSet(root: root, group: candidate, disposition: .automatic, expected: expected, dependencies: baselineDependencies))
    }
}
