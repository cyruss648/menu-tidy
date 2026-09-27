import XCTest
@testable import MenuTidyCore

final class NativeOwnerRecoveryQueueTests: XCTestCase {
    private func owner(id: String = "item", pid: Int32 = 42, launch: Double = 100) -> ObservedItemGroupHistory.Identity {
        .init(id: id, pid: pid, bundleIdentifier: "org.example.App", launchTime: launch)
    }

    func testBusyScanKeepsDepartedEpochForLaterRecovery() {
        var queue = NativeOwnerRecoveryQueue<String>()
        queue.register(target: "app", departedOwner: owner())
        XCTAssertTrue(queue.readyTargets(canRestore: false, liveTargets: [], ownerIsCurrent: { _ in false }).isEmpty)
        XCTAssertEqual(queue.pendingTargets, ["app"])
        // The next scan need not still contain the original AX snapshot.
        XCTAssertEqual(queue.readyTargets(canRestore: true, liveTargets: [], ownerIsCurrent: { _ in false }), ["app"])
    }

    func testLiveSiblingBlocksSharedPreferenceRestorationUntilItAlsoDeparts() {
        var queue = NativeOwnerRecoveryQueue<String>()
        queue.register(target: "app", departedOwner: owner(id: "first", pid: 42))
        XCTAssertTrue(queue.readyTargets(canRestore: true, liveTargets: ["app"], ownerIsCurrent: { _ in false }).isEmpty)
        queue.register(target: "app", departedOwner: owner(id: "second", pid: 43))
        XCTAssertEqual(queue.readyTargets(canRestore: true, liveTargets: [], ownerIsCurrent: { _ in false }), ["app"])
    }

    func testPIDReuseDoesNotMakeTheDepartedEpochCurrent() {
        var queue = NativeOwnerRecoveryQueue<String>()
        let old = owner()
        let relaunched = owner(launch: 200)
        queue.register(target: "app", departedOwner: old)
        XCTAssertEqual(queue.readyTargets(canRestore: true, liveTargets: [], ownerIsCurrent: { $0 == relaunched }), ["app"])
        XCTAssertTrue(queue.readyTargets(canRestore: true, liveTargets: [], ownerIsCurrent: { $0 == old }).isEmpty)
    }

    func testFailedRestorationDoesNotRetryOnRepeatedDiscoveryOrNewEpoch() {
        var queue = NativeOwnerRecoveryQueue<String>()
        queue.register(target: "app", departedOwner: owner())
        queue.recordFailure(target: "app")
        queue.register(target: "app", departedOwner: owner())
        queue.register(target: "app", departedOwner: owner(launch: 200))
        XCTAssertEqual(queue.failedTargets, ["app"])
        XCTAssertTrue(queue.readyTargets(canRestore: true, liveTargets: [], ownerIsCurrent: { _ in false }).isEmpty)
        // Only successful explicit restoration releases this ownership entry.
        queue.complete(target: "app")
        queue.register(target: "app", departedOwner: owner(launch: 300))
        XCTAssertEqual(queue.readyTargets(canRestore: true, liveTargets: [], ownerIsCurrent: { _ in false }), ["app"])
    }

    func testIndependentTargetCanRecoverWhenOneFailedOrHasLiveOwner() {
        var queue = NativeOwnerRecoveryQueue<String>()
        for target in ["failed", "live", "ready"] { queue.register(target: target, departedOwner: owner(id: target)) }
        queue.recordFailure(target: "failed")
        XCTAssertEqual(queue.readyTargets(canRestore: true, liveTargets: ["live"], ownerIsCurrent: { _ in false }), ["ready"])
        queue.retainManagedTargets(["failed", "live"])
        XCTAssertEqual(queue.pendingTargets, ["failed", "live"])
    }

    func testUnknownEpochCannotCreateRecoveryAuthority() {
        var queue = NativeOwnerRecoveryQueue<String>()
        for launch in [0, -1, Double.infinity, Double.nan] {
            queue.register(target: "app", departedOwner: owner(launch: launch))
        }
        XCTAssertTrue(queue.pendingTargets.isEmpty)
    }
}
