import Darwin
import Foundation
import MenuTidyCore

/// Exact-key preferences only. AX identity binding, layout refresh and actual
/// position verification remain the caller's responsibility. No input is sent.
@MainActor
final class MenuBarPositionStore {
    struct Transaction: Equatable, Sendable {
        let id: UUID
        let sourceKey: String
        let anchorKey: String
        let originalValues: [String: Double]
        let writtenValues: [String: Double]
    }

    struct RollbackResult: Sendable {
        let restoredKeys: Set<String>
        let alreadyRestoredKeys: Set<String>
        let conflictedKeys: Set<String>
        let missingKeys: Set<String>
        var isComplete: Bool { conflictedKeys.isEmpty && missingKeys.isEmpty }
    }

    struct ManagedHiddenEntry {
        let key: String
        let originalValue: Double
        let hiddenValue: Double
        let lastAppWrite: Double?
        let mode: MenuBarHiddenLedger.Mode
        let recoveryPending: Bool
    }

    struct HiddenMutationResult {
        var changedKeys: Set<String> = []
        var conflictedKeys: Set<String> = []
        var missingKeys: Set<String> = []
        var pendingRecoveryKeys: Set<String> = []
        var requiresLayoutRefresh = false
        var isComplete: Bool {
            conflictedKeys.isEmpty && missingKeys.isEmpty && pendingRecoveryKeys.isEmpty
        }

        mutating func merge(_ other: HiddenMutationResult) {
            changedKeys.formUnion(other.changedKeys)
            conflictedKeys.formUnion(other.conflictedKeys)
            missingKeys.formUnion(other.missingKeys)
            pendingRecoveryKeys.formUnion(other.pendingRecoveryKeys)
            requiresLayoutRefresh = requiresLayoutRefresh || other.requiresLayoutRefresh
        }
    }

    struct StoreFailure: LocalizedError {
        let reason: String
        /// A write may have reached CFPreferences. Retain this token whenever
        /// automatic conditional rollback could not be confirmed completely.
        let recoveryTransaction: Transaction?
        /// A preference may have briefly reached the host even when the store
        /// already restored it; the caller must still refresh its own layout.
        let requiresLayoutRefresh: Bool
        var errorDescription: String? { reason }
    }

    private struct ActiveTransaction {
        let token: Transaction
        let originalNumbers: [String: NSNumber]
        let writtenNumbers: [String: NSNumber]
    }

    private var active: [UUID: ActiveTransaction] = [:]
    private var journalContents: Data?
    private var hiddenRecords: [String: MenuBarHiddenLedger.Entry] = [:]
    private var hiddenLedgerContents: Data?
    private(set) var hiddenLedgerRecoveryIssue: String?
    var managedHiddenEntries: [ManagedHiddenEntry] {
        hiddenRecords.values.sorted { $0.key < $1.key }.map {
            ManagedHiddenEntry(key: $0.key, originalValue: $0.originalValue.doubleValue,
                hiddenValue: $0.hiddenValue.doubleValue, lastAppWrite: $0.lastAppWrite?.doubleValue,
                mode: $0.mode, recoveryPending: $0.pending != nil)
        }
    }
    var pendingHiddenRecoveryKeys: Set<String> {
        Set(hiddenRecords.values.filter { $0.pending != nil }.map(\.key))
    }
    private(set) var recoveryJournalIssue: String?
    /// Only the fixed active journal is loaded, never historical backup files.
    var pendingTransactions: [Transaction] {
        active.values.map(\.token).sorted { $0.id.uuidString < $1.id.uuidString }
    }
    private let key = "TrailingItemPreferredPositions" as CFString
    private var domainURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            "Library/Group Containers/com.apple.MenuBar/Library/Preferences/com.apple.MenuBar")
    }
    private var domain: CFString { domainURL.path as CFString }

    init() {
        do {
            let data = try readJournal()
            let entries = try data.map(MenuBarPositionJournal.decode) ?? []
            for entry in entries {
                let token = Transaction(id: entry.id, sourceKey: entry.sourceKey, anchorKey: entry.anchorKey,
                    originalValues: entry.originalValues.mapValues(\.doubleValue),
                    writtenValues: entry.writtenValues.mapValues(\.doubleValue))
                active[token.id] = ActiveTransaction(token: token, originalNumbers: entry.originalValues,
                                                    writtenNumbers: entry.writtenValues)
            }
            journalContents = data
        } catch {
            recoveryJournalIssue = "待恢复的位置事务日志无法安全读取。已停止新的后台排序，请保留 Transactions 目录以便检查。"
        }
        do {
            let data = try readHiddenLedger()
            let records = try data.map(MenuBarHiddenLedger.decode) ?? []
            hiddenRecords = Dictionary(uniqueKeysWithValues: records.map { ($0.key, $0) })
            hiddenLedgerContents = data
        } catch {
            hiddenLedgerRecoveryIssue = "持久隐藏记录无法安全读取，已停止位置写入。请保留 Transactions/HiddenItems.plist 以便恢复。"
        }
    }

    func readPositions() throws -> [String: Double] {
        try readNumbers().mapValues(\.doubleValue)
    }

    func readValues(for keys: Set<String>) throws -> [String: Double] {
        let positions = try readPositions()
        var result: [String: Double] = [:]
        for key in keys {
            guard let value = positions[key] else { throw failure("指定图标的位置记录不存在。") }
            result[key] = value
        }
        return result
    }

    /// These entry points own only exact, existing preference keys. The caller
    /// must prove current AX/owner identity before invoking them and refresh and
    /// inspect native layout afterwards. A result never proves visual hiding.
    func hide(key: String) throws -> HiddenMutationResult {
        try requireHiddenWriteAccess(key: key)
        return try preservingHiddenRefresh(key: key) { result in
            guard result.isComplete else { return result }
            let current = try readNumbers()
            guard let value = current[key] else {
                result.missingKeys.insert(key)
                return result
            }
            let entry: MenuBarHiddenLedger.Entry
            if let existing = hiddenRecords[key] {
                guard existing.lastAppWrite?.isEqual(to: value) == true else {
                    result.conflictedKeys.insert(key)
                    return result
                }
                if existing.mode == .hidden { return result }
                entry = existing
            } else {
                let weight = try MenuBarHiddenLedger.allocateHiddenWeight(
                    positions: current, entries: Array(hiddenRecords.values))
                entry = MenuBarHiddenLedger.Entry(key: key, originalValue: value,
                    hiddenValue: weight, lastAppWrite: nil, mode: .original)
            }
            result.merge(try writeHiddenPosition(entry.preparing(.hide, value: entry.hiddenValue)))
            return result
        }
    }

    func temporarilyReveal(key: String, before controlKey: String) throws -> HiddenMutationResult {
        try requireHiddenWriteAccess(key: key, anchorKey: controlKey)
        return try preservingHiddenRefresh(key: key) { result in
            guard result.isComplete else { return result }
            guard let entry = hiddenRecords[key] else { throw failure("此图标没有持久隐藏记录，尚未临时显示。") }
            let current = try readNumbers()
            guard let actual = current[key] else { result.missingKeys.insert(key); return result }
            guard entry.lastAppWrite?.isEqual(to: actual) == true else {
                result.conflictedKeys.insert(key)
                return result
            }
            if entry.mode == .temporarilyRevealed { return result }
            guard entry.mode == .hidden, hiddenRecords[controlKey] == nil else {
                throw failure("临时显示的参考位置仍处于隐藏管理中，未改变位置。")
            }
            let plan = try MenuBarPositionPlan.moving(key, before: controlKey,
                                                    positions: current.mapValues(\.doubleValue))
            guard plan.writtenWeight < MenuBarHiddenLedger.minimumHiddenWeight else {
                throw failure("参考位置不在普通菜单栏位置区间，尚未临时显示。")
            }
            result.merge(try writeHiddenPosition(entry.preparing(.temporarilyReveal,
                value: NSNumber(value: plan.writtenWeight)), positionPlan: plan))
            return result
        }
    }

    func restoreTemporaryReveal(key: String) throws -> HiddenMutationResult {
        try requireHiddenWriteAccess(key: key)
        return try preservingHiddenRefresh(key: key) { result in
            guard result.isComplete, let entry = hiddenRecords[key] else { return result }
            let current = try readNumbers()
            guard let actual = current[key] else { result.missingKeys.insert(key); return result }
            guard entry.lastAppWrite?.isEqual(to: actual) == true else {
                result.conflictedKeys.insert(key)
                return result
            }
            if entry.mode == .hidden { return result }
            guard entry.mode == .temporarilyRevealed else { throw failure("隐藏位置仍有未完成记录。") }
            result.merge(try writeHiddenPosition(entry.preparing(.restoreTemporaryReveal, value: entry.hiddenValue)))
            return result
        }
    }

    /// End ownership only after restoring the exact original NSNumber, or after
    /// observing that it is already restored. External edits and missing keys
    /// remain recorded and are never overwritten or recreated.
    func restoreHidden(key: String) throws -> HiddenMutationResult {
        try requireHiddenWriteAccess(key: key)
        return try preservingHiddenRefresh(key: key) { result in
            guard result.isComplete, let entry = hiddenRecords[key] else { return result }
            let current = try readNumbers()
            guard let actual = current[key] else { result.missingKeys.insert(key); return result }
            if actual.isEqual(to: entry.originalValue) {
                var next = hiddenRecords
                next.removeValue(forKey: key)
                try saveHiddenRecords(next)
                return result
            }
            guard entry.lastAppWrite?.isEqual(to: actual) == true else {
                result.conflictedKeys.insert(key)
                return result
            }
            result.merge(try writeHiddenPosition(entry.preparing(.restoreOriginal, value: entry.originalValue)))
            return result
        }
    }

    /// Only for an explicit user choice to keep the current native layout.
    /// Never reads or writes system preferences, and never clears ActiveJournal.
    func abandonAllHidden() throws {
        try saveHiddenRecords([:])
        hiddenLedgerRecoveryIssue = nil
    }

    func restoreAllHidden() throws -> HiddenMutationResult {
        try requireHiddenStorageHealthy()
        var result = HiddenMutationResult()
        do {
            for key in hiddenRecords.keys.sorted() {
                result.merge(try restoreHidden(key: key))
            }
        } catch {
            throw failure(error.localizedDescription, requiresLayoutRefresh:
                result.requiresLayoutRefresh || (error as? StoreFailure)?.requiresLayoutRefresh == true)
        }
        return result
    }

    /// Resolve crash-interrupted writes using the persisted before/after values.
    /// This method never writes system preferences or replays a failed action.
    func recoverPendingHiddenWrites() throws -> HiddenMutationResult {
        try requireHiddenStorageHealthy()
        var result = HiddenMutationResult()
        do {
            for key in pendingHiddenRecoveryKeys.sorted() {
                result.merge(try recoverHiddenWrite(key: key))
            }
        } catch {
            throw failure(error.localizedDescription, requiresLayoutRefresh:
                result.requiresLayoutRefresh || (error as? StoreFailure)?.requiresLayoutRefresh == true)
        }
        return result
    }

    private func requireHiddenStorageHealthy() throws {
        if let issue = recoveryJournalIssue { throw failure(issue) }
        if let issue = hiddenLedgerRecoveryIssue { throw failure(issue) }
    }

    /// Preserve a recovered write's refresh requirement even if a later read,
    /// plan, or ledger update throws before the caller can merge this result.
    private func preservingHiddenRefresh(key: String,
        operation: (inout HiddenMutationResult) throws -> HiddenMutationResult) throws -> HiddenMutationResult {
        var result = HiddenMutationResult()
        do {
            result = try recoverHiddenWrite(key: key)
            return try operation(&result)
        } catch {
            let original = error as? StoreFailure
            throw failure(error.localizedDescription, transaction: original?.recoveryTransaction,
                requiresLayoutRefresh: result.requiresLayoutRefresh || original?.requiresLayoutRefresh == true)
        }
    }

    private func requireHiddenWriteAccess(key: String, anchorKey: String? = nil) throws {
        try requireHiddenStorageHealthy()
        guard !active.values.contains(where: {
            $0.token.sourceKey == key || $0.token.anchorKey == key ||
                (anchorKey != nil && $0.token.sourceKey == anchorKey)
        }) else { throw failure("此位置仍有普通排序事务，未同时修改隐藏位置。") }
    }

    private func recoverHiddenWrite(key: String) throws -> HiddenMutationResult {
        guard let entry = hiddenRecords[key], entry.pending != nil else { return HiddenMutationResult() }
        let current = try readNumbers()
        var result = HiddenMutationResult()
        switch MenuBarHiddenLedger.recovery(for: entry, current: current[key]) {
        case .completed(let replacement), .notApplied(let replacement):
            var next = hiddenRecords
            next[key] = replacement
            // A host may have consumed the write even when the app crashed
            // before its refresh; even failed ledger finalization must preserve
            // the caller's obligation to re-read native layout.
            do { try saveHiddenRecords(next) }
            catch { throw failure(error.localizedDescription, requiresLayoutRefresh: true) }
            result.requiresLayoutRefresh = true
        case .conflicted:
            result.conflictedKeys.insert(key)
            result.pendingRecoveryKeys.insert(key)
        case .missing:
            result.missingKeys.insert(key)
            result.pendingRecoveryKeys.insert(key)
        case .unchanged: break
        }
        return result
    }

    private func writeHiddenPosition(_ prepared: MenuBarHiddenLedger.Entry,
                                     positionPlan: MenuBarPositionPlan? = nil) throws -> HiddenMutationResult {
        guard let pending = prepared.pending else { throw failure("隐藏位置写入缺少持久意图。") }
        var staged = hiddenRecords
        staged[prepared.key] = prepared
        // A durable complete record exists before any system write. Encoding
        // validates exact scope, numeric types and state transitions as well.
        try saveHiddenRecords(staged)
        var attempted = false
        do {
            var fresh = try readNumbers()
            guard fresh[prepared.key]?.isEqual(to: pending.expectedValue) == true else {
                throw failure("隐藏位置准备期间已被外部更改，未覆盖新值。")
            }
            if let positionPlan { _ = try positionPlan.applying(to: fresh.mapValues(\.doubleValue)) }
            if pending.operation == .hide || pending.operation == .restoreTemporaryReveal {
                guard !fresh.contains(where: { $0.key != prepared.key && $0.value.isEqual(to: pending.writtenValue) }) else {
                    throw failure("预留的隐藏位置已被其他图标占用，未覆盖任何位置。")
                }
            }
            fresh[prepared.key] = pending.writtenValue
            attempted = true
            try writeNumbers(fresh)
            let readback = try readNumbers()
            guard readback[prepared.key]?.isEqual(to: pending.writtenValue) == true else {
                throw failure("隐藏位置写入尚未确认，已保留持久恢复记录。")
            }
            var completed = hiddenRecords
            completed[prepared.key] = prepared.completingPending()
            try saveHiddenRecords(completed)
            return HiddenMutationResult(changedKeys: [prepared.key], requiresLayoutRefresh: true)
        } catch {
            // Do not replay or blindly roll back an uncertain write. The next
            // recovery compares the persisted expected/desired values exactly.
            throw failure(error.localizedDescription, requiresLayoutRefresh: attempted)
        }
    }

    /// Writes only an existing source key after preserving its exact original
    /// NSNumber. The token must be committed only after actual AX verification.
    func move(key sourceKey: String, before anchorKey: String) throws -> Transaction {
        try move(key: sourceKey, relativeTo: anchorKey, placement: .before)
    }

    /// Uses the same journal and rollback contract as `before`. A second move
    /// for this source is rejected until its previous token has been finalized.
    func move(key sourceKey: String, after anchorKey: String) throws -> Transaction {
        try move(key: sourceKey, relativeTo: anchorKey, placement: .after)
    }

    /// Reposition only our fixed divider between the complete ordinary weight
    /// range and managed hidden slots. The caller proves the live own AX item,
    /// refreshes its layout, and commits only after its visible position is
    /// verified. nil leaves an already-separated divider exactly unchanged.
    func positionOwnDividerAtHiddenBoundary() throws -> Transaction? {
        try requireHiddenStorageHealthy()
        guard !hiddenRecords.isEmpty else { return nil }
        let sourceKey = MenuBarOwnBoundaryPlan.dividerKey
        let anchorKey = MenuBarOwnBoundaryPlan.controlKey
        guard hiddenRecords[sourceKey] == nil, hiddenRecords[anchorKey] == nil,
              !active.values.contains(where: {
                  $0.token.sourceKey == sourceKey || $0.token.anchorKey == sourceKey || $0.token.sourceKey == anchorKey
              }) else {
            throw failure("本应用分隔项仍有未完成的位置事务，尚未调整隐藏边界。")
        }
        let initial = try readNumbers()
        try validateHiddenBoundaryOwnership(initial)
        let plan: MenuBarOwnBoundaryPlan
        do {
            guard let prepared = try MenuBarOwnBoundaryPlan.prepare(positions: initial.mapValues(\.doubleValue),
                managedHiddenWeights: hiddenRecords.mapValues { $0.hiddenValue.doubleValue }) else { return nil }
            plan = prepared
        } catch { throw failure("普通位置与隐藏位置之间没有可确认的有限间隙，未调整本应用分隔项。") }
        guard let original = initial[sourceKey] else { throw failure("本应用分隔项的位置记录不存在。") }
        return try executePositionPlan(sourceKey: sourceKey, anchorKey: anchorKey,
            originalNumber: original, writtenWeight: plan.writtenWeight) { current in
            try self.validateHiddenBoundaryOwnership(current)
            _ = try plan.applying(to: current.mapValues(\.doubleValue))
        }
    }

    private func validateHiddenBoundaryOwnership(_ current: [String: NSNumber]) throws {
        // Do not adjust an enclosing boundary during temporary item display or
        // unresolved writes. Check exact NSNumber ownership on every fresh read.
        guard !hiddenRecords.isEmpty, hiddenRecords.values.allSatisfy({ entry in
            entry.mode == .hidden && entry.pending == nil &&
                entry.hiddenValue.doubleValue >= MenuBarHiddenLedger.minimumHiddenWeight &&
                entry.lastAppWrite?.isEqual(to: entry.hiddenValue) == true &&
                current[entry.key]?.isEqual(to: entry.hiddenValue) == true
        }) else { throw failure("隐藏项仍在临时显示、恢复或外部更改状态，未调整本应用分隔项。") }
    }

    private func move(key sourceKey: String, relativeTo anchorKey: String,
                      placement: MenuBarPositionPlan.Placement) throws -> Transaction {
        if let issue = recoveryJournalIssue { throw failure(issue) }
        if let issue = hiddenLedgerRecoveryIssue { throw failure(issue) }
        guard hiddenRecords[sourceKey] == nil, hiddenRecords[anchorKey] == nil else {
            throw failure("指定图标处于持久隐藏管理中，请先结束其隐藏管理，再执行普通排序。")
        }
        guard !active.values.contains(where: { $0.token.sourceKey == sourceKey }) else {
            throw failure("此图标还有未结束的位置事务，请先确认或恢复。")
        }
        let initial = try readNumbers()
        let plan: MenuBarPositionPlan
        do {
            let positions = initial.mapValues(\.doubleValue)
            switch placement {
            case .before: plan = try .moving(sourceKey, before: anchorKey, positions: positions)
            case .after: plan = try .moving(sourceKey, after: anchorKey, positions: positions)
            }
        }
        catch { throw failure("指定位置之间没有可确认的有限权重间隙，未修改位置。") }
        guard let originalNumber = initial[sourceKey] else { throw failure("指定图标的位置记录不存在。") }
        return try executePositionPlan(sourceKey: sourceKey, anchorKey: anchorKey,
            originalNumber: originalNumber, writtenWeight: plan.writtenWeight) { current in
            _ = try plan.applying(to: current.mapValues(\.doubleValue))
        }
    }

    /// Shared single-key journal/CAS protocol. The validator observes only a
    /// freshly read table and must not mutate it. Both ordinary moves and the
    /// own-divider boundary retain exact original NSNumber representations.
    private func executePositionPlan(sourceKey: String, anchorKey: String,
                                     originalNumber: NSNumber, writtenWeight: Double,
                                     validate: ([String: NSNumber]) throws -> Void) throws -> Transaction {
        let transaction = Transaction(id: UUID(), sourceKey: sourceKey, anchorKey: anchorKey,
            originalValues: [sourceKey: originalNumber.doubleValue], writtenValues: [sourceKey: writtenWeight])
        let record = ActiveTransaction(token: transaction, originalNumbers: [sourceKey: originalNumber],
            writtenNumbers: [sourceKey: NSNumber(value: writtenWeight)])
        try writeBackup(record)

        // Backup I/O is outside the final read/merge/write window. Never write
        // the initial full dictionary back over newer unrelated preferences.
        let prepared = try readNumbers()
        do { try validate(prepared) }
        catch { throw failure("准备期间位置记录已变化，未写入旧计划。") }
        guard prepared[sourceKey]?.isEqual(to: originalNumber) == true else {
            throw failure("准备期间原始位置值已变化，未写入旧计划。")
        }
        active[transaction.id] = record
        do { try persistJournal(active) }
        catch {
            recoveryJournalIssue = "位置事务日志未能持久保存，尚未写入系统位置；本次事务仍保留以便确认。"
            throw failure(recoveryJournalIssue!, transaction: transaction)
        }
        do {
            // Journal I/O also precedes a final fresh merge. The durable entry
            // exists before any system write, including an uncertain write.
            var fresh = try readNumbers()
            try validate(fresh)
            guard fresh[sourceKey]?.isEqual(to: originalNumber) == true else {
                throw failure("准备期间原始位置值已变化。")
            }
            fresh[sourceKey] = record.writtenNumbers[sourceKey]
            try writeNumbers(fresh)
            let readback = try readNumbers()
            guard let expected = record.writtenNumbers[sourceKey], readback[sourceKey]?.isEqual(to: expected) == true else {
                throw failure("位置写入尚未确认。", transaction: transaction)
            }
            return transaction
        } catch {
            let restored = try? rollback(transaction)
            throw failure(restored?.isComplete == true
                ? "位置写入未确认，已恢复本次原值。"
                : "位置写入未确认，仍有待恢复的位置事务；未覆盖外部变化。",
                transaction: restored?.isComplete == true ? nil : transaction, requiresLayoutRefresh: true)
        }
    }

    func commit(_ transaction: Transaction) throws {
        guard let record = active[transaction.id], record.token == transaction else { throw failure("位置事务已结束或不属于当前实例。") }
        do {
            let current = try readNumbers()
            guard record.writtenNumbers.allSatisfy({ current[$0.key]?.isEqual(to: $0.value) == true }) else {
                throw failure("确认期间位置记录已变化。")
            }
        } catch {
            throw failure("确认期间位置记录已变化，事务仍保留以便恢复。", transaction: transaction)
        }
        try finalize(transaction)
    }

    /// Only after an explicit user choice to retain the current layout. This
    /// removes the pending record without reading or writing system positions.
    func abandon(_ transaction: Transaction) throws {
        guard let record = active[transaction.id], record.token == transaction else {
            throw failure("位置事务已结束或不属于当前实例。")
        }
        try finalize(transaction)
    }

    func rollback(_ transaction: Transaction) throws -> RollbackResult {
        guard let record = active[transaction.id], record.token == transaction else { throw failure("位置事务已结束或不属于当前实例。") }
        do {
            var current = try readNumbers()
            let plan = try MenuBarPositionPlan.rollback(originalValues: transaction.originalValues,
                writtenValues: transaction.writtenValues, current: current.mapValues(\.doubleValue))
            var conflicts = plan.conflictedKeys
            var restoring: Set<String> = []
            var already = plan.alreadyRestoredKeys
            // Double is the planning format only. Match and restore the exact
            // stored NSNumber values so an integer is never truncated/retyped.
            for key in plan.alreadyRestoredKeys {
                guard let original = record.originalNumbers[key], current[key]?.isEqual(to: original) == true else {
                    already.remove(key)
                    conflicts.insert(key)
                    continue
                }
            }
            for key in plan.restorations.keys {
                guard let expected = record.writtenNumbers[key], current[key]?.isEqual(to: expected) == true,
                      let original = record.originalNumbers[key] else { conflicts.insert(key); continue }
                current[key] = original
                restoring.insert(key)
            }
            if !restoring.isEmpty { try writeNumbers(current) }
            let readback = try readNumbers()
            var restored: Set<String> = []
            var missing = plan.missingKeys
            for key in restoring.union(already) {
                guard let value = readback[key] else { missing.insert(key); already.remove(key); continue }
                guard let original = record.originalNumbers[key], value.isEqual(to: original) else {
                    conflicts.insert(key)
                    already.remove(key)
                    continue
                }
                if restoring.contains(key) { restored.insert(key) }
            }
            let result = RollbackResult(restoredKeys: restored, alreadyRestoredKeys: already,
                conflictedKeys: conflicts, missingKeys: missing)
            if result.isComplete { try finalize(transaction) }
            return result
        } catch {
            if let error = error as? StoreFailure, error.recoveryTransaction != nil { throw error }
            throw failure("无法确认位置恢复结果，事务仍保留；未猜测或重建缺失记录。", transaction: transaction)
        }
    }

    private func finalize(_ transaction: Transaction) throws {
        var remaining = active
        remaining.removeValue(forKey: transaction.id)
        do { try persistJournal(remaining) }
        catch {
            recoveryJournalIssue = "待恢复事务日志尚未完成清理；事务仍保留，请重新检测后确认。"
            throw failure(recoveryJournalIssue!, transaction: transaction)
        }
        active = remaining
        recoveryJournalIssue = nil
    }

    private func readNumbers() throws -> [String: NSNumber] {
        // Use the preferences service directly. A GUI process may be unable to
        // stat another app's group-container file even when the service permits
        // access; a filesystem probe is not the capability being requested.
        guard CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost),
              let raw = CFPreferencesCopyValue(key, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost),
              CFGetTypeID(raw) == CFDictionaryGetTypeID(), let dictionary = raw as? NSDictionary,
              dictionary.count > 0 else { throw failure("系统菜单栏位置表为空或无法读取。") }
        var result: [String: NSNumber] = [:]
        for (key, value) in dictionary {
            guard let key = key as? String, let number = value as? NSNumber,
                  CFGetTypeID(number) == CFNumberGetTypeID(), number.doubleValue.isFinite else {
                throw failure("系统位置表包含未知类型或非有限数值，未修改位置。")
            }
            result[key] = number
        }
        return result
    }

    private func writeNumbers(_ values: [String: NSNumber]) throws {
        CFPreferencesSetValue(key, values as CFDictionary, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        guard CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else {
            throw failure("系统位置偏好同步未确认。")
        }
    }

    private let journalName = "ActiveJournal.plist"
    private let hiddenLedgerName = "HiddenItems.plist"

    private func saveHiddenRecords(_ records: [String: MenuBarHiddenLedger.Entry]) throws {
        let data = try records.isEmpty ? nil : MenuBarHiddenLedger.encode(Array(records.values))
        do {
            try persistHiddenLedger(data)
            hiddenRecords = records
        } catch {
            hiddenLedgerRecoveryIssue = "持久隐藏记录尚未安全保存，已停止后续位置写入；请保留 HiddenItems.plist 并重新启动恢复。"
            throw failure(hiddenLedgerRecoveryIssue!)
        }
    }

    private func readHiddenLedger() throws -> Data? {
        guard let directory = try transactionDirectory(createIfMissing: false) else { return nil }
        let directoryFD = try openTransactionDirectory(directory)
        defer { close(directoryFD) }
        let descriptor = openat(directoryFD, hiddenLedgerName, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if descriptor < 0 {
            guard errno == ENOENT else { throw failure("持久隐藏记录无法安全打开。") }
            return nil
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == geteuid(), (info.st_mode & 0o7777) == 0o600, info.st_nlink == 1,
              info.st_size > 0, info.st_size <= MenuBarHiddenLedger.maximumDataSize,
              let data = try handle.read(upToCount: MenuBarHiddenLedger.maximumDataSize + 1),
              data.count == info.st_size else { throw failure("持久隐藏记录的类型、权限、大小或完整性不符合要求。") }
        return data
    }

    private func persistHiddenLedger(_ data: Data?) throws {
        guard let directory = try transactionDirectory(createIfMissing: true) else {
            throw failure("持久隐藏记录目录无法创建。")
        }
        guard try readHiddenLedger() == hiddenLedgerContents else {
            throw failure("持久隐藏记录已被外部修改，未覆盖现有记录。")
        }
        let directoryFD = try openTransactionDirectory(directory)
        defer { close(directoryFD) }
        guard let data else {
            if hiddenLedgerContents != nil {
                guard unlinkat(directoryFD, hiddenLedgerName, 0) == 0 else { throw failure("持久隐藏记录无法清理。") }
                hiddenLedgerContents = nil
            }
            guard fsync(directoryFD) == 0, try readHiddenLedger() == nil else {
                throw failure("持久隐藏记录清理尚未确认。")
            }
            return
        }
        let temporaryName = ".HiddenItems-\(UUID().uuidString).tmp"
        let descriptor = openat(directoryFD, temporaryName,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw failure("持久隐藏记录无法创建。") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer {
            try? handle.close()
            unlinkat(directoryFD, temporaryName, 0)
        }
        guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else { throw failure("持久隐藏记录权限无法确认。") }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        guard try readHiddenLedger() == hiddenLedgerContents,
              renameat(directoryFD, temporaryName, directoryFD, hiddenLedgerName) == 0 else {
            throw failure("持久隐藏记录已变化或无法原子替换。")
        }
        hiddenLedgerContents = data
        guard fsync(directoryFD) == 0, try readHiddenLedger() == data else {
            throw failure("持久隐藏记录持久保存尚未确认。")
        }
    }

    /// Reject symlink/non-directory components and other-user writable paths.
    /// Loading is read-only and does not create the application support tree.
    private func transactionDirectory(createIfMissing: Bool) throws -> URL? {
        var directory = FileManager.default.homeDirectoryForCurrentUser
        for component in ["", "Library", "Application Support", "Menu Tidy", "Transactions"] {
            if !component.isEmpty { directory.appendPathComponent(component, isDirectory: true) }
            var info = stat()
            if lstat(directory.path, &info) != 0 {
                guard errno == ENOENT else { throw failure("位置事务目录无法安全读取。") }
                guard createIfMissing else { return nil }
                guard mkdir(directory.path, S_IRWXU) == 0,
                      lstat(directory.path, &info) == 0 else { throw failure("位置事务目录无法安全创建。") }
            }
            guard (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == geteuid(),
                  (info.st_mode & 0o022) == 0 else { throw failure("位置事务目录的路径或权限不安全。") }
        }
        return directory
    }

    private func openTransactionDirectory(_ directory: URL) throws -> Int32 {
        let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw failure("位置事务目录无法安全打开。") }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == geteuid(), (info.st_mode & 0o022) == 0 else {
            close(descriptor)
            throw failure("位置事务目录的路径或权限不安全。")
        }
        return descriptor
    }

    private func readJournal() throws -> Data? {
        guard let directory = try transactionDirectory(createIfMissing: false) else { return nil }
        let directoryFD = try openTransactionDirectory(directory)
        defer { close(directoryFD) }
        let descriptor = openat(directoryFD, journalName, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if descriptor < 0 {
            guard errno == ENOENT else { throw failure("待恢复事务日志无法安全打开。") }
            return nil
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == geteuid(), (info.st_mode & 0o7777) == 0o600, info.st_nlink == 1,
              info.st_size > 0, info.st_size <= MenuBarPositionJournal.maximumDataSize else {
            throw failure("待恢复事务日志的类型、权限或大小不符合要求。")
        }
        guard let data = try handle.read(upToCount: MenuBarPositionJournal.maximumDataSize + 1),
              data.count == info.st_size else { throw failure("待恢复事务日志读取不完整。") }
        return data
    }

    /// A same-directory atomic rename leaves either the previous complete
    /// journal or the new one after a crash. Historical backup files are kept.
    private func persistJournal(_ records: [UUID: ActiveTransaction]) throws {
        guard let directory = try transactionDirectory(createIfMissing: true) else {
            throw failure("位置事务目录无法创建。")
        }
        guard try readJournal() == journalContents else {
            throw failure("待恢复事务日志已被外部修改，未覆盖现有记录。")
        }
        let directoryFD = try openTransactionDirectory(directory)
        defer { close(directoryFD) }
        if records.isEmpty {
            if journalContents != nil {
                guard unlinkat(directoryFD, journalName, 0) == 0 else { throw failure("待恢复事务日志无法删除。") }
                journalContents = nil
            }
            guard fsync(directoryFD) == 0, try readJournal() == nil else {
                throw failure("待恢复事务日志清理尚未确认。")
            }
            return
        }
        let entries = records.values.map {
            MenuBarPositionJournal.Entry(id: $0.token.id, sourceKey: $0.token.sourceKey, anchorKey: $0.token.anchorKey,
                originalValues: $0.originalNumbers, writtenValues: $0.writtenNumbers)
        }
        let data = try MenuBarPositionJournal.encode(entries)
        let temporaryName = ".ActiveJournal-\(UUID().uuidString).tmp"
        let descriptor = openat(directoryFD, temporaryName,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw failure("待恢复事务日志无法创建。") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer {
            try? handle.close()
            unlinkat(directoryFD, temporaryName, 0)
        }
        guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else { throw failure("待恢复事务日志权限无法确认。") }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        // Do not replace an externally changed journal while writing the temp.
        guard try readJournal() == journalContents,
              renameat(directoryFD, temporaryName, directoryFD, journalName) == 0 else {
            throw failure("待恢复事务日志已变化或无法替换。")
        }
        journalContents = data
        guard fsync(directoryFD) == 0, try readJournal() == data else {
            throw failure("待恢复事务日志持久保存尚未确认。")
        }
    }

    private func writeBackup(_ record: ActiveTransaction) throws {
        do {
            let manager = FileManager.default
            guard let directory = try transactionDirectory(createIfMissing: true) else {
                throw failure("位置事务备份目录无法创建。")
            }
            let payload: [String: Any] = ["schemaVersion": 1, "transactionID": record.token.id.uuidString,
                "createdAt": Date(), "domain": domain as String, "key": key as String,
                "sourceKey": record.token.sourceKey, "anchorKey": record.token.anchorKey,
                "originalValues": record.originalNumbers, "writtenValues": record.writtenNumbers]
            let data = try PropertyListSerialization.data(fromPropertyList: payload, format: .binary, options: 0)
            let filename = "\(Int64(Date().timeIntervalSince1970 * 1_000))-\(record.token.id.uuidString).plist"
            let file = directory.appendingPathComponent(filename)
            let descriptor = open(file.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
            guard descriptor >= 0 else { throw failure("位置事务备份无法创建。") }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? handle.close() }
            guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else { throw failure("位置事务备份权限无法确认。") }
            try handle.write(contentsOf: data)
            try handle.synchronize()
            guard (try manager.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600 else {
                throw failure("位置事务备份权限无法确认。")
            }
        } catch { throw failure("无法创建私有位置事务备份，未修改系统位置。") }
    }

    private func failure(_ reason: String, transaction: Transaction? = nil,
                         requiresLayoutRefresh: Bool = false) -> StoreFailure {
        StoreFailure(reason: reason, recoveryTransaction: transaction,
                     requiresLayoutRefresh: requiresLayoutRefresh || transaction != nil)
    }
}
