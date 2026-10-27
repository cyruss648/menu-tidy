import AppKit
import Darwin
import Foundation
import OSLog

/// Controls third-party menu bar applications through macOS 27's private
/// MenuBarClientCore assessment allow-list. The assertion is process-owned:
/// releasing it restores the menu bar without touching the user's persistent
/// Menu Bar settings.
///
/// This backend is deliberately application-scoped. MenuBarAgent accepts
/// bundle identifiers, so all status items belonging to one application are
/// shown or hidden together.
@MainActor
final class NativeMenuBarAssessmentStore {
    private static let logger = Logger(subsystem: "dev.hdh.MenuTidy", category: "NativeAssessment")
    private static let frameworkPath = "/System/Library/PrivateFrameworks/MenuBarClientCore.framework/MenuBarClientCore"
    private static let configurationClassName = "MBAssessmentModeConfiguration"
    private static let assertionClassName = "MBAssessmentModeAssertion"
    private static let configurationInitializer = "initWithAllowedSystemItems:allowedBundleIdentifiers:"
    private static let activationSelector = "activateWithConfiguration:completionHandler:"
    private static let invalidationSelector = "invalidate"
    private static let systemOwners: Set<String> = [
        "com.apple.MenuBarAgent", "com.apple.controlcenter", "com.apple.systemuiserver"
    ]

    private struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private let configurationClass: NSObject.Type?
    private let assertionClass: NSObject.Type?
    private let canActivate: Bool
    private var assertion: NSObject?
    private var configuration: NSObject?
    private var pendingActivation: Task<Void, Error>?
    private var generation = 0
    private var observedBundles: Set<String> = []
    private(set) var ownedBundles: Set<String> = []
    private(set) var hiddenBundles: Set<String> = []
    private(set) var revealedBundles: Set<String> = []
    private(set) var allowedBundles: Set<String> = []
    private(set) var lastError: String?

    init() {
        _ = dlopen(Self.frameworkPath, RTLD_NOW | RTLD_LOCAL)
        let configurationClass = NSClassFromString(Self.configurationClassName) as? NSObject.Type
        let assertionClass = NSClassFromString(Self.assertionClassName) as? NSObject.Type
        self.configurationClass = configurationClass
        self.assertionClass = assertionClass
        guard let configurationClass, let assertionClass else {
            canActivate = false
            return
        }
        let configurationSelector = NSSelectorFromString(Self.configurationInitializer)
        let activationSelector = NSSelectorFromString(Self.activationSelector)
        let invalidationSelector = NSSelectorFromString(Self.invalidationSelector)
        canActivate = ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 &&
            configurationClass.instancesRespond(to: configurationSelector) &&
            assertionClass.instancesRespond(to: activationSelector) &&
            assertionClass.instancesRespond(to: invalidationSelector)
    }

    var isAvailable: Bool { canActivate }
    var isActive: Bool { assertion != nil }
    var managedBundles: Set<String> { ownedBundles }

    func syncDesiredHiddenBundles(_ bundles: Set<String>) {
        guard canActivate else { return }
        let filtered = bundles.filter(Self.isApplicationBundle)
        hiddenBundles = filtered
        ownedBundles.formUnion(filtered)
        revealedBundles.subtract(filtered)
    }

    func isManaged(bundle: String) -> Bool { ownedBundles.contains(bundle) }
    func isTemporarilyRevealed(bundle: String) -> Bool { revealedBundles.contains(bundle) }
    func isAllowed(bundle: String) -> Bool { !hiddenBundles.contains(bundle) }

    func refresh(observedBundles: Set<String>) {
        guard canActivate, !hiddenBundles.isEmpty else { return }
        self.observedBundles.formUnion(observedBundles.filter(Self.isApplicationBundle))
        scheduleAssertion()
    }

    /// Apply a set of application-wide visibility changes and wait for the
    /// private assertion callback. A timeout fails closed for this operation;
    /// the caller keeps its draft and can retry after the desktop is ready.
    func changeVisibility(_ changes: [String: Bool], observedBundles: Set<String>) async
        -> [String: Result<Void, Error>] {
        guard canActivate else {
            let error = Failure(message: "当前 macOS 未提供可用的原生菜单栏隐藏后端。选择已保留。")
            return Dictionary(uniqueKeysWithValues: changes.keys.map { ($0, .failure(error)) })
        }
        pendingActivation?.cancel()
        pendingActivation = nil
        generation += 1
        let nextGeneration = generation
        self.observedBundles.formUnion(observedBundles.filter(Self.isApplicationBundle))
        var nextHidden = hiddenBundles
        for (bundle, hidden) in changes {
            guard Self.isApplicationBundle(bundle) else { continue }
            ownedBundles.insert(bundle)
            if hidden {
                nextHidden.insert(bundle)
                revealedBundles.remove(bundle)
            } else {
                nextHidden.remove(bundle)
                revealedBundles.remove(bundle)
                ownedBundles.remove(bundle)
            }
        }
        hiddenBundles = nextHidden
        do {
            try await applyAssertion(generation: nextGeneration)
            lastError = nil
            return Dictionary(uniqueKeysWithValues: changes.keys.map { ($0, .success(())) })
        } catch {
            lastError = error.localizedDescription
            invalidate()
            let failure = error as NSError
            return Dictionary(uniqueKeysWithValues: changes.keys.map { ($0, .failure(failure)) })
        }
    }

    /// A panel action needs one target visible while the rest remain hidden.
    /// Keep the current assertion until the replacement is active: invalidating
    /// it first would make every application visible during the native action.
    func temporarilyReveal(bundle: String) async throws {
        guard canActivate, ownedBundles.contains(bundle) else {
            throw Failure(message: "此应用的隐藏开关不由 Menu Tidy 管理，未改变系统显示设置。")
        }
        pendingActivation?.cancel()
        pendingActivation = nil
        generation += 1
        let nextGeneration = generation
        let previousHiddenBundles = hiddenBundles
        let previousRevealedBundles = revealedBundles
        hiddenBundles.remove(bundle)
        revealedBundles.insert(bundle)
        do {
            try await applyAssertion(generation: nextGeneration)
            lastError = nil
        } catch {
            hiddenBundles = previousHiddenBundles
            revealedBundles = previousRevealedBundles
            lastError = error.localizedDescription
            throw error
        }
    }

    func rehide(bundle: String) {
        guard canActivate, ownedBundles.contains(bundle) else { return }
        revealedBundles.remove(bundle)
        hiddenBundles.insert(bundle)
        scheduleAssertion()
    }

    func restore(bundle: String) {
        guard ownedBundles.contains(bundle) else { return }
        revealedBundles.remove(bundle)
        hiddenBundles.remove(bundle)
        ownedBundles.remove(bundle)
        if hiddenBundles.isEmpty {
            invalidate()
        } else {
            scheduleAssertion()
        }
    }

    func restoreAll() {
        pendingActivation?.cancel()
        pendingActivation = nil
        generation += 1
        hiddenBundles.removeAll()
        revealedBundles.removeAll()
        ownedBundles.removeAll()
        invalidate()
    }

    func invalidate() {
        pendingActivation?.cancel()
        pendingActivation = nil
        generation += 1
        releaseAssertion()
        lastError = nil
    }

    /// Wait for a re-hide scheduled by a synchronous cleanup path. Initial
    /// application changes already await their own activation directly.
    func waitForPendingActivation() async throws {
        guard let pendingActivation else { return }
        self.pendingActivation = nil
        try await pendingActivation.value
    }

    static func allowedBundleIdentifiers(ownBundle: String,
                                         observedBundles: Set<String>,
                                         runningBundles: Set<String>,
                                         hiddenBundles: Set<String>,
                                         systemOwners: Set<String> = systemOwners) -> Set<String> {
        let candidates = observedBundles.union(runningBundles).union(systemOwners).union([ownBundle])
        return candidates.subtracting(hiddenBundles).union(systemOwners).union([ownBundle])
    }

    private func scheduleAssertion() {
        guard canActivate else { return }
        pendingActivation?.cancel()
        generation += 1
        let taskGeneration = generation
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            try await self.applyAssertion(generation: taskGeneration)
        }
        pendingActivation = task
    }

    private func applyAssertion(generation requestedGeneration: Int) async throws {
        guard requestedGeneration == generation, !hiddenBundles.isEmpty else {
            if hiddenBundles.isEmpty { releaseAssertion() }
            return
        }
        let own = Bundle.main.bundleIdentifier ?? "dev.hdh.MenuTidy"
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let allowed = Self.allowedBundleIdentifiers(ownBundle: own,
            observedBundles: observedBundles, runningBundles: running,
            hiddenBundles: hiddenBundles)
        let nextConfiguration = try makeConfiguration(allowed: allowed.sorted())
        let nextAssertion = try await activateWithTimeout(configuration: nextConfiguration)
        guard requestedGeneration == generation, !hiddenBundles.isEmpty else {
            nextAssertion.perform(NSSelectorFromString(Self.invalidationSelector))
            return
        }
        let previous = assertion
        assertion = nextAssertion
        configuration = nextConfiguration
        allowedBundles = allowed
        previous?.perform(NSSelectorFromString(Self.invalidationSelector))
        Self.logger.notice("assessment active=true allowedBundles=\(allowed.count) hiddenBundles=\(self.hiddenBundles.count)")
    }

    private func makeConfiguration(allowed: [String]) throws -> NSObject {
        guard let configurationClass else {
            throw Failure(message: "无法加载 macOS 菜单栏原生显示后端。")
        }
        let configurationSelector = NSSelectorFromString(Self.configurationInitializer)
        // The private implementation indexes both arguments as NSArray. An
        // NSSet is accepted by Swift bridging but throws inside the framework.
        let systemItems = (0..<64).map { NSNumber(value: $0) } as NSArray
        let raw = (configurationClass as AnyObject).perform(NSSelectorFromString("alloc"))
            .map { $0.takeUnretainedValue() }
        guard let raw,
              let configuration = raw.perform(configurationSelector, with: systemItems,
                  with: allowed as NSArray)?.takeRetainedValue() as? NSObject else {
            throw Failure(message: "macOS 菜单栏原生显示后端拒绝了当前允许列表。")
        }
        return configuration
    }

    private final class ActivationState: @unchecked Sendable {
        var completed = false
    }

    private final class ObjectReference: @unchecked Sendable {
        let value: NSObject
        init(_ value: NSObject) { self.value = value }
    }

    private func activateWithTimeout(configuration: NSObject) async throws -> NSObject {
        guard let assertionClass else {
            throw Failure(message: "无法创建 macOS 菜单栏原生显示断言。")
        }
        let assertion = assertionClass.init()
        let selector = NSSelectorFromString(Self.activationSelector)
        let result: ObjectReference = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ObjectReference, Error>) in
            let state = ActivationState()
            let timeout = DispatchWorkItem {
                guard !state.completed else { return }
                state.completed = true
                continuation.resume(throwing: Failure(message: "macOS 菜单栏原生显示后端响应超时，选择已保留。"))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: timeout)
            typealias Activate = @convention(c) (AnyObject, Selector, AnyObject,
                @escaping @convention(block) (NSError?) -> Void) -> Void
            let activate = unsafeBitCast(assertion.method(for: selector), to: Activate.self)
            activate(assertion, selector, configuration) { error in
                DispatchQueue.main.async {
                    guard !state.completed else { return }
                    state.completed = true
                    timeout.cancel()
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume(returning: ObjectReference(assertion)) }
                }
            }
        }
        return result.value
    }

    private func releaseAssertion() {
        assertion?.perform(NSSelectorFromString(Self.invalidationSelector))
        assertion = nil
        configuration = nil
        allowedBundles.removeAll()
    }

    private static func isApplicationBundle(_ bundle: String) -> Bool {
        guard !bundle.isEmpty, bundle != Bundle.main.bundleIdentifier,
              !bundle.lowercased().hasPrefix("com.apple.") else { return false }
        return bundle.utf8.count <= 255 && bundle.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) ||
                (48...57).contains($0) || $0 == 45 || $0 == 46 || $0 == 95
        }
    }
}
