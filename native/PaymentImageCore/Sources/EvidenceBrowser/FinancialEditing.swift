#if os(macOS) || os(iOS)
import Foundation
import PaymentImageCore

/// The form receives business values and an opaque optimistic-edit token.
/// Expected bytes and dependency keys belong to the Store, never the View.
struct FactEdit: Sendable, Identifiable {
    let id = UUID()
    let record: FinancialLifecycle
    let original: FinancialLifecycle
    let initial: TransactionFactReview
    fileprivate let context: OverrideEditContext
    fileprivate let expectedDocument: Data
    fileprivate let expected: Data?
}

/// A concrete snapshot of the Store's editing context, not a new service layer.
struct OverrideEditContext: Sendable {
    let root: URL
    let datasetID: String
    let generation: UUID
    let base: FinancialReport
    let catalog: CategoryCatalog?
    let projectionVersion: String
    let catalogVersion: String
    let from: String
    let to: String
    let saved: Set<String>
    let prepareQueues: Bool

    func validateOnDisk() throws {
        let projection = try Data(contentsOf: ReviewDataSource.url("financial-review.json", root: root))
        let catalogURL = root.appendingPathComponent("category-catalog.json")
        let catalog = FileManager.default.fileExists(atPath: catalogURL.path) ? try Data(contentsOf: catalogURL) : nil
        guard ReviewFileVersion.of(projection) == projectionVersion,
              ReviewFileVersion.of(catalog) == catalogVersion else { throw CompletionWriteError.conflict }
    }
    func project(_ document: Data) throws -> OverrideProjection {
        let values = try JSONDecoder().decode([String: CategoryOverride].self, from: document)
        var report = base
        FinancialStore.applyCompletion(values, to: &report, catalog: catalog)
        return OverrideProjection(document: document, overrides: values, report: report,
            search: FinancialStore.searchIndex(report.records),
            tags: Array(Set(report.records.flatMap(\.components).flatMap(\.tags))).sorted(),
            queues: prepareQueues ? CompletionQueue.prepared(report, from: from, to: to, includeIDs: saved, rootPath: root.path) : [:])
    }
}
struct OverrideProjection: Sendable {
    let document: Data
    let overrides: [String: CategoryOverride]
    let report: FinancialReport
    let search: [String: String]
    let tags: [String]
    let queues: [String: [CompletionEntry]]
}

extension FinancialStore {
    func editContext(saved: Set<String>? = nil, prepareQueues: Bool = false) throws -> OverrideEditContext {
        guard let root, let report, let baseReport,
              let projection = sourceVersions["financial-review.json"],
              let catalog = sourceVersions["category-catalog.json"] else { throw CompletionWriteError.conflict }
        return OverrideEditContext(root: root, datasetID: report.dataset_id, generation: editingGeneration,
            base: baseReport, catalog: categoryCatalog, projectionVersion: projection, catalogVersion: catalog,
            from: completion.from, to: completion.to, saved: saved ?? completion.saved, prepareQueues: prepareQueues)
    }
    func isCurrent(_ context: OverrideEditContext) -> Bool {
        root == context.root && report?.dataset_id == context.datasetID && editingGeneration == context.generation &&
        sourceVersions["financial-review.json"] == context.projectionVersion &&
        sourceVersions["category-catalog.json"] == context.catalogVersion
    }
    /// One background rebuild and one cache adoption for every override operation.
    /// Per-field CAS remains in CompletionOverrideFile. The lease excludes the
    /// existing processor; it is not the future Release multi-file transaction.
    func performOverrideEdit<T: Sendable>(_ context: OverrideEditContext,
        write: @escaping @Sendable (URL, URL?) throws -> (T, Data)) async throws -> T {
        guard isCurrent(context), !Task.isCancelled else { throw CompletionWriteError.conflict }
        let previousDocument = overrideDocument
        let session = workspaceEditSession
        let client = familyClientEditSession
        let verifiedClient = pinnedClientReview != nil
        let result = try await Task.detached(priority: .userInitiated) {
            if let session {
                let (written, state) = try await session.writeScheduled { root, config in
                    try context.validateOnDisk()
                    let (value, document) = try write(root, config)
                    return (value, try context.project(document))
                }
                return (written.0, Optional(written.1), Optional(state), Optional<ReviewFamilyClientHandle>.none)
            }
            if let client {
                let (written, handle) = try client.write { root, config in
                    try context.validateOnDisk()
                    let (value, document) = try write(root, config)
                    return (value, try context.project(document))
                }
                return (written.0, Optional(written.1), Optional<StateHandle>.none, Optional(handle))
            }
            let lease = try ReviewProcessLease(root: context.root)
            defer { withExtendedLifetime(lease) {} }
            let (value, document) = try Self.withLocalReviewMutation(root: context.root, verifiedClient: verifiedClient) {
                try context.validateOnDisk()
                return try write(context.root, nil)
            }
            let projection = try document == previousDocument ? nil : context.project(document)
            return (value, projection, Optional<StateHandle>.none, Optional<ReviewFamilyClientHandle>.none)
        }.value
        guard isCurrent(context) else { throw CompletionWriteError.conflict }
        if let projection = result.1 { try adoptEdit(projection, context: context) }
        if let state = result.2 { adoptWorkspaceState(state) }
        if let handle = result.3 { adoptFamilyClientEdit(handle) }
        return result.0
    }
    func adoptEdit(_ projection: OverrideProjection, context: OverrideEditContext) throws {
        guard isCurrent(context) else { throw CompletionWriteError.conflict }
        overrideDocument = projection.document; overrides = projection.overrides
        adoptProjection(projection.report)
        invalidateCompletionCaches(search: projection.search, tags: projection.tags)
        preparedCompletionQueues = projection.queues
        completion.undo = nil
    }
    func beginFactEdit(_ record: FinancialLifecycle) -> FactEdit? {
        do {
            guard !categoryBusy, report?.records.contains(record) == true,
                  let original = baseReport?.records.first(where: { $0.id == record.id }) else { throw CompletionWriteError.conflict }
            return FactEdit(record: record, original: original,
                initial: try overrides[record.reviewOverrideKey]?.transaction_facts ?? TransactionFactReview(record: original),
                context: try editContext(), expectedDocument: overrideDocument,
                expected: try CompletionOverrideFile.entry(record.reviewOverrideKey, in: overrideDocument))
        } catch { self.error = "交易已更新，请重新打开事实确认。"; return nil }
    }
    func scheduleEditDiscovery() {
        #if os(macOS)
        Task { [weak self] in await self?.discoverMerchantTags() }
        #endif
    }
    func resetFacts(_ record: FinancialLifecycle) async -> Bool {
        guard let edit = beginFactEdit(record) else { return false }
        return await saveFacts(edit, review: nil)
    }
}

extension FinancialStore {
    func saveFacts(_ edit: FactEdit, review: TransactionFactReview?) async -> Bool {
        let record = edit.record
        let expected = edit.expected
        guard !categoryBusy, isCurrent(edit.context), root != nil, let baseReport, let report,
              let live = report.records.first(where: { $0.id == record.id }), live == record,
              let original = baseReport.records.first(where: { $0.id == record.id }) else {
            error = "交易已更新或正在处理，请重新打开事实确认。"; return false
        }
        completionSaving = true; defer { completionSaving = false }
        do {
            let clean = try review.map { try TransactionFacts.validated($0, source: original, records: baseReport.records, cutoff: report.cutoff ?? "") }
            if let clean {
                var projected = overrides
                projected[record.reviewOverrideKey] = CategoryOverride(primary: "", secondary: "", excluded_from_completion_and_statistics: overrides[record.reviewOverrideKey]?.excluded_from_completion_and_statistics, transaction_facts: clean, source_record_set_review: overrides[record.reviewOverrideKey]?.source_record_set_review)
                var preview = baseReport; Self.applyCompletion(projected, to: &preview, catalog: categoryCatalog)
                guard preview.records.first(where: { $0.id == record.id })?.fact_review_status?.hasPrefix("事实已确认") == true else {
                    throw FactReviewError.invalid(preview.records.first(where: { $0.id == record.id })?.fact_review_status ?? "事实确认无法应用，请核对关联目标。")
                }
            }
            var dependencyKeys = Set<String>()
            let related = [clean, overrides[record.reviewOverrideKey]?.transaction_facts].compactMap { $0 }
                .reduce(into: Set<String>()) { $0.formUnion(TransactionFacts.relatedRecordIDs($1, records: baseReport.records)) }
            for item in baseReport.records where related.contains(item.id) || item.events.contains(where: { $0.kind == "refund" || $0.kind == "bank_credit" }) {
                if item.id != record.id { dependencyKeys.insert(item.reviewOverrideKey) }
            }
            if let targetID = clean?.targetID, let target = baseReport.records.first(where: { $0.id == targetID || $0.components.contains { $0.id == targetID } }) { dependencyKeys.insert(target.reviewOverrideKey) }
            let affectedIDs = Set(original.components.map(\.id) + [record.id] + [clean?.targetID].compactMap { $0 })
            for (key, value) in overrides where key != record.reviewOverrideKey {
                if let target = value.transaction_facts?.targetID, affectedIDs.contains(target) { dependencyKeys.insert(key) }
            }
            let dependencies = try CompletionOverrideFile.dependencies(Array(dependencyKeys), in: edit.expectedDocument)
            let savedIDs = Set(original.components.map(\.id) + [record.id + ":facts"])
            let nextSaved = clean == nil ? completion.saved.subtracting(savedIDs) : completion.saved.union(savedIDs)
            let context = try editContext(saved: nextSaved)
            _ = try await performOverrideEdit(context) { root, _ in
                let write = try CompletionOverrideFile.saveFacts(root: root, record: original, review: clean, expected: expected, dependencies: dependencies)
                return (write, write.document)
            }
            if clean == nil { completion.saved.subtract(savedIDs) } else { completion.saved.formUnion(savedIDs) }
            if selected == record.id { directDetailID = record.id }
            scheduleEditDiscovery(); completion.message = clean == nil ? "已恢复原始证据判断。" : "事实确认已保存，统计已更新。"
            completion.undo = nil; error = nil; return true
        } catch { self.error = "事实未保存：" + error.localizedDescription; return false }
    }
    func setReviewExcluded(_ record: FinancialLifecycle, value: Bool) async {
        guard !categoryBusy, root != nil, let report,
              let live = report.records.first(where: { $0.id == record.id }), live == record,
              live.canExcludeFromReview || (live.reviewExcluded && !value) else { return }
        completionSaving = true; defer { completionSaving = false }
        do {
            let expected = try CompletionOverrideFile.entry(record.reviewOverrideKey, in: overrideDocument)
            let context = try editContext()
            _ = try await performOverrideEdit(context) { root, _ in
                let write = try CompletionOverrideFile.setExcluded(root: root, record: live, value: value, expected: expected)
                return (write, write.document)
            }
            scheduleEditDiscovery()
            completion.message = value ? "已从补全和统计中排除整笔交易；可在「已排除」恢复。" : "已恢复补全与统计，原有待核事实仍保留。"
            error = nil
        } catch { self.error = "排除状态未保存：" + error.localizedDescription }
    }

    func reconcileCompletion() async {
        guard !categoryBusy,
              let root, let report, completion.root == root, completion.dataset == report.dataset_id else { return }
        let expected = overrideDocument
        let excluded = Set(completion.drafts.keys).union(completion.automaticExcluded)
        let expectedRevision = revision
        let expectedGeneration = editingGeneration
        do {
            let plan = try await Task.detached(priority: .userInitiated) {
                try CompletionOverrideFile.prepareConfirmed(records: report.records, expectedDocument: expected, excluding: excluded)
            }.value
            guard let plan, !Task.isCancelled, !categoryBusy,
                  self.root == root, editingGeneration == expectedGeneration, revision == expectedRevision, overrideDocument == expected,
                  Set(completion.drafts.keys).union(completion.automaticExcluded) == excluded else { return }
            completionSaving = true; defer { completionSaving = false }
            let context = try editContext()
            let result = try await performOverrideEdit(context) { root, _ in
                let write = try CompletionOverrideFile.applyConfirmed(root: root, plan: plan)
                return (write, write.document)
            }
            completion.message = "已根据已有人工确认自动完成 \(result.saved.count) 项；可在「已确认」复查。"
            error = nil
        } catch { self.error = "自动确认未完成：" + error.localizedDescription }
    }
    func saveCompletion(_ entry: CompletionEntry) async -> Bool {
        guard !categoryBusy, let root, let report,
              completion.root == root, completion.dataset == report.dataset_id, entry.datasetID == report.dataset_id, entry.rootPath == root.path, let component = entry.component,
              let raw = completion.draft(entry) else { return false }
        completionSaving = true; defer { completionSaving = false }
        do {
            // A refresh must not silently rebase an old draft onto different field values.
            if let base = completion.draftBases[entry.id], base != CompletionDraft(component) { throw CompletionWriteError.conflict }
            guard let live = report.records.lazy.flatMap({ $0.components }).first(where: { $0.id == entry.id }), CompletionDraft(live) == CompletionDraft(component) else { throw CompletionWriteError.conflict }
            let draft = try raw.validated(taxonomy: report.taxonomy)
            let expectedDocument = overrideDocument
            let targets = CategoryHeuristics.linkedTargets(source: component, draft: draft, records: report.records, excluding: Set(completion.drafts.keys))
            let affected = [component] + targets
            let dependencyKeys = affected.flatMap { $0.classification_keys ?? [] }.filter { key in !affected.contains { $0.id == key } }
            let context = try editContext(saved: completion.saved.union(affected.map(\.id)), prepareQueues: true)
            let start = DispatchTime.now().uptimeNanoseconds
            let result = try await performOverrideEdit(context) { root, _ in
                let write = try CompletionOverrideFile.saveLinked(root: root, source: component, draft: draft, targets: targets, expectedDocument: expectedDocument)
                return (write, write.document)
            }
            completion.undo = CompletionUndo(id: entry.id, previous: result.previous, expected: result.saved, root: self.root ?? root, datasetID: report.dataset_id, dependencies: try CompletionOverrideFile.dependencies(dependencyKeys, in: result.document))
            completion.drafts.removeValue(forKey: entry.id); completion.draftBases.removeValue(forKey: entry.id)
            completion.saved.formUnion(affected.map(\.id))
            completion.message = entry.factsPending ? "字段已保存；关联、身份或统计问题仍需核实。" : "字段已保存。"
            if !targets.isEmpty { completion.message += " 已联动补齐 \(targets.count) 项同名商家并记为已确认（含区间外）；可整批撤销。" }
            ReviewLatency.record("completion-save", milliseconds: Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            error = nil; return true
        } catch { self.error = "补全未保存：" + error.localizedDescription; return false }
    }
    func undoCompletion() async {
        guard !categoryBusy, let undo = completion.undo, undo.root == root, undo.datasetID == report?.dataset_id, completion.root == root, completion.dataset == report?.dataset_id else { return }
        completionSaving = true; defer { completionSaving = false }
        do {
            let context = try editContext(saved: completion.saved.subtracting(undo.previous.keys), prepareQueues: true)
            _ = try await performOverrideEdit(context) { root, _ in
                let write = try CompletionOverrideFile.restoreLinked(root: root, previous: undo.previous, expected: undo.expected, dependencies: undo.dependencies)
                return (write, write.document)
            }
            completion.automaticExcluded.formUnion(undo.previous.keys)
            completion.saved.subtract(undo.previous.keys); completion.drafts.removeValue(forKey: undo.id); completion.draftBases.removeValue(forKey: undo.id)
            completion.undo = nil; completion.selected = undo.id; completion.message = "已撤销上一笔字段保存及其同名联动。"
            error = nil
        } catch { self.error = "撤销未完成：" + error.localizedDescription }
    }
}

extension FinancialStore {
    var sourceRecordGroups: [SourceRecordSet] {
        guard let report else { return [] }
        return TransactionListOrder.sorted(SourceRecordSets.groups(report), amount: \.amount_cents, date: \.date, id: \.id)
    }
    func saveSourceSet(_ group: SourceRecordSet, disposition: SourceRecordSetDisposition) async -> Bool {
        guard !categoryBusy, root != nil, let baseReport,
              sourceRecordGroups.contains(group) else { error = "来源组已更新，请重新打开详情。"; return false }
        completionSaving = true; defer { completionSaving = false }
        do {
            let expected = try CompletionOverrideFile.entry(group.reviewOverrideKey, in: overrideDocument)
            var projected = overrides
            projected[group.reviewOverrideKey] = CategoryOverride(primary: "", secondary: "", source_record_set_review: SourceRecordSetReview(fingerprint: group.fingerprint, disposition: disposition))
            var preview = baseReport
            SourceRecordSets.apply(projected, to: &preview)
            if disposition == .confirm {
                guard let result = SourceRecordSets.groups(preview).first(where: { $0.id == group.id }), result.confirmed else {
                    throw FactReviewError.invalid(SourceRecordSets.groups(preview).first(where: { $0.id == group.id })?.review_reason ?? "当前来源事实存在冲突，暂不能归并。")
                }
            }
            // Include absent lifecycle entries: a concurrent fact/association save
            // must invalidate the group save as well as an existing member edit.
            var keys = Set(baseReport.records.map(\.reviewOverrideKey))
            keys.formUnion(SourceRecordSets.groups(baseReport).map(\.reviewOverrideKey))
            keys.formUnion(overrides.keys); keys.remove(group.reviewOverrideKey)
            let dependencies = try CompletionOverrideFile.dependencies(Array(keys), in: overrideDocument)
            let context = try editContext()
            _ = try await performOverrideEdit(context) { root, _ in
                let write = try CompletionOverrideFile.saveSourceSet(root: root, group: group, disposition: disposition, expected: expected, dependencies: dependencies)
                return (write, write.document)
            }
            scheduleEditDiscovery()
            completion.message = disposition == .confirm ? "整组来源已确认，保留银行记录，统计已更新。" : disposition == .reject ? "已撤销归并并保留各来源记录。" : "已恢复自动规则，请查看当前整组状态。"
            error = nil; return true
        } catch { self.error = "来源组未保存：" + error.localizedDescription; return false }
    }
}

extension FinancialStore {
    func confirmRefundCandidate(_ candidate: RefundCandidate) async -> Bool {
        guard let baseReport, let report, baseReport.refund_candidates?.contains(candidate) == true,
              let anchor = candidate.source_ids.sorted().first,
              let current = report.records.first(where: { $0.id == anchor }),
              candidate.source_ids.allSatisfy({ id in
                  report.records.contains(where: { $0.id == id && $0.unallocated_credit_cents > 0 && !$0.reviewExcluded && !$0.non_consumption }) &&
                    overrides["transaction:" + id]?.transaction_facts == nil
              }) else { error = "退款候选或事实确认已更新，请重新打开详情。"; return false }
        do {
            let review = try RefundAssociations.review(candidate, records: baseReport.records)
            guard let edit = beginFactEdit(current) else { return false }
            return await saveFacts(edit, review: review)
        } catch { self.error = error.localizedDescription; return false }
    }
}

extension FinancialStore {
    func rebindCategoryTransactions(_ entries: [CompletionEntry], targetID: String, expectedCatalog: CategoryCatalog, expectedDocument: Data) async -> Bool {
        guard !categoryBusy, let root, let report, let baseReport, categoryCatalog == expectedCatalog,
              overrideDocument == expectedDocument,
              let target = expectedCatalog.secondaries.first(where: { $0.id == targetID }),
              let parent = expectedCatalog.primaries.first(where: { $0.id == target.primaryID }), !entries.isEmpty else {
            error = "分类或交易已更新，请重新选择后操作。"; return false
        }
        let live = Dictionary(uniqueKeysWithValues: report.records.flatMap(\.components).map { ($0.id, $0) })
        guard entries.allSatisfy({ entry in
            entry.rootPath == root.path && entry.datasetID == report.dataset_id && entry.component != nil &&
            live[entry.id].map { CompletionDraft($0) == CompletionDraft(entry.component!) } == true
        }) else { error = "所选交易已更新，请重新选择后操作。"; return false }
        categorySaving = true; defer { categorySaving = false }
        do {
            let components = entries.compactMap(\.component)
            let idsToRemove = Set(entries.map(\.id))
            let context = try editContext(saved: completion.saved.subtracting(idsToRemove))
            _ = try await performOverrideEdit(context) { root, _ in
                guard try CategoryCatalogFile.load(root: root, taxonomy: baseReport.taxonomy, records: baseReport.records) == expectedCatalog else { throw CompletionWriteError.conflict }
                let write = try CompletionOverrideFile.rebindCategories(root: root, components: components, primary: parent.name, secondary: target.name, expectedDocument: expectedDocument)
                return (write, write.document)
            }
            let ids = Set(entries.map(\.id))
            completion.drafts = completion.drafts.filter { !ids.contains($0.key) }
            completion.draftBases = completion.draftBases.filter { !ids.contains($0.key) }
            completion.saved.subtract(ids); completion.undo = nil; completion.automaticExcluded.formUnion(ids)
            categoryMessage = "已将 \(entries.count) 个消费项目移至「\(parent.name) / \(target.name)」，用途需重新确认。"
            error = nil; return true
        } catch { self.error = "批量操作未保存：" + error.localizedDescription; return false }
    }

    func classify(_ id: String, primary: String, secondary: String, recurrence: String? = nil, tags: [String]? = nil) {
        guard !categoryBusy, let root, let report, report.taxonomy.contains(where: { $0.primary == primary && $0.secondaries.contains(secondary) }) else { return }
        guard let component = report.records.lazy.flatMap({ $0.components }).first(where: { $0.id == id }) else { return }
        let cleaned = Array(Set((tags ?? component.tags).map {
            $0.precomposedStringWithCanonicalMapping.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        }.filter { !$0.isEmpty })).sorted()
        guard cleaned.count <= 30, cleaned.allSatisfy({ $0.count <= 40 }) else { error = "每笔最多30个标签，每个标签最多40字。"; return }
        let value = CategoryOverride(primary: primary, secondary: secondary, recurrence: recurrence ?? component.effectiveRecurrence, tags: cleaned)
        do {
            let draft = try CompletionDraft(component).validated(taxonomy: report.taxonomy)
            var updated = draft
            updated.primary = value.primary; updated.secondary = value.secondary
            updated.recurrence = value.recurrence ?? "one_time"; updated.tags = cleaned
            let context = try editContext()
            if workspacePaths == nil && familyClientHandle == nil {
            let lease = try ReviewProcessLease(root: root)
            defer { withExtendedLifetime(lease) {} }
            let write = try Self.withLocalReviewMutation(root: root, verifiedClient: pinnedClientReview != nil) {
                try context.validateOnDisk()
                return try CompletionOverrideFile.save(root: root, id: id, draft: try updated.validated(taxonomy: report.taxonomy), expected: CompletionOverrideFile.entry(id, in: overrideDocument), dependencies: CompletionOverrideFile.dependencies(component.classification_keys ?? [], in: overrideDocument), previousTags: component.tags)
            }
            try adoptEdit(context.project(write.document), context: context)
                scheduleEditDiscovery(); error = nil; return
            }
            let expected = try CompletionOverrideFile.entry(id, in: overrideDocument)
            let dependencies = try CompletionOverrideFile.dependencies(component.classification_keys ?? [], in: overrideDocument)
            let validated = try updated.validated(taxonomy: report.taxonomy)
            completionSaving = true
            Task {
                defer { completionSaving = false }
                do {
                    _ = try await performOverrideEdit(context) { root, _ in
                        let write = try CompletionOverrideFile.save(root: root, id: id, draft: validated, expected: expected, dependencies: dependencies, previousTags: component.tags)
                        return (write, write.document)
                    }
                    scheduleEditDiscovery(); error = nil
                } catch { self.error = "分类未保存：" + error.localizedDescription }
            }
            scheduleEditDiscovery()
            error = nil
        } catch { self.error = "分类未保存：" + error.localizedDescription }
    }
}
#endif
