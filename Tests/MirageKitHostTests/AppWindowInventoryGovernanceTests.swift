//
//  AppWindowInventoryGovernanceTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/28/26.
//
//  App-stream runtime policy tests.
//

#if os(macOS)
@testable import MirageKitHost
import Foundation
import MirageKit
import Testing

@Suite("App Streaming Governance")
struct AppWindowInventoryGovernanceTests {
    @Test("Ownership signal classifier ignores passive/noisy signals")
    func ownershipSignalClassifierIgnoresPassiveSignals() {
        let moved = MirageInputEvent.mouseMoved(MirageMouseEvent(location: .zero))
        let flags = MirageInputEvent.flagsChanged([])

        #expect(!AppStreamRuntimeOrchestrator.isOwnershipSwitchSignal(moved))
        #expect(!AppStreamRuntimeOrchestrator.isOwnershipSwitchSignal(flags))
    }

    @Test("Ownership signal classifier accepts focus, clicks, and key down")
    func ownershipSignalClassifierAcceptsSwitchSignals() {
        #expect(AppStreamRuntimeOrchestrator.isOwnershipSwitchSignal(.windowFocus))
        #expect(AppStreamRuntimeOrchestrator.isOwnershipSwitchSignal(.mouseDown(MirageMouseEvent(location: .zero))))
        #expect(AppStreamRuntimeOrchestrator.isOwnershipSwitchSignal(.keyDown(MirageKeyEvent(keyCode: 0))))
    }

    @Test("Orchestrator ownership hysteresis prevents rapid ping-pong")
    func orchestratorOwnershipHysteresisPreventsPingPong() async {
        let orchestrator = AppStreamRuntimeOrchestrator()
        await orchestrator.registerStream(bundleIdentifier: "com.example.app", streamID: 1)
        await orchestrator.registerStream(bundleIdentifier: "com.example.app", streamID: 2)

        await orchestrator.forceOwnership(streamID: 1, now: 1.0)
        #expect(await orchestrator.requestOwnershipSwitch(streamID: 2, now: 1.1) == false)
        #expect(await orchestrator.requestOwnershipSwitch(streamID: 2, now: 1.2) == false)
        #expect(await orchestrator.requestOwnershipSwitch(streamID: 2, now: 1.5) == true)
    }

    @Test("Previous active stream retains live tier briefly after ownership switch")
    func previousActiveStreamUsesDemotionGrace() async throws {
        let orchestrator = AppStreamRuntimeOrchestrator()
        await orchestrator.registerStream(bundleIdentifier: "com.example.app", streamID: 1)
        await orchestrator.registerStream(bundleIdentifier: "com.example.app", streamID: 2)

        await orchestrator.forceOwnership(streamID: 1, now: 1.0)
        await orchestrator.forceOwnership(streamID: 2, now: 2.0)

        let duringGrace = await orchestrator.makeRuntimePolicySnapshot(
            bundleIdentifier: "com.example.app",
            visibleStreamIDs: [1, 2],
            bitrateBudgetBps: 8_000_000,
            activeTargetFPS: 60,
            now: 2.25
        )
        let duringGraceStreamOne = try #require(duringGrace.policies.first(where: { $0.streamID == 1 }))
        let duringGraceStreamTwo = try #require(duringGrace.policies.first(where: { $0.streamID == 2 }))
        let transitionAt = try #require(duringGrace.nextPolicyTransitionAt)

        #expect(duringGrace.activeStreamID == 2)
        #expect(duringGraceStreamOne.tier == .activeLive)
        #expect(duringGraceStreamTwo.tier == .activeLive)
        #expect(abs(transitionAt - 2.5) < 0.001)

        let afterGrace = await orchestrator.makeRuntimePolicySnapshot(
            bundleIdentifier: "com.example.app",
            visibleStreamIDs: [1, 2],
            bitrateBudgetBps: 8_000_000,
            activeTargetFPS: 60,
            now: 2.60
        )
        let afterGraceStreamOne = try #require(afterGrace.policies.first(where: { $0.streamID == 1 }))
        let afterGraceStreamTwo = try #require(afterGrace.policies.first(where: { $0.streamID == 2 }))

        #expect(afterGrace.activeStreamID == 2)
        #expect(afterGrace.nextPolicyTransitionAt == nil)
        #expect(afterGraceStreamOne.tier == .passiveSnapshot)
        #expect(afterGraceStreamTwo.tier == .activeLive)
    }

    @Test("Bitrate allocation is deterministic with active-first weighting and passive floors")
    func bitrateAllocationDeterministic() async throws {
        let orchestrator = AppStreamRuntimeOrchestrator()
        await orchestrator.registerStream(bundleIdentifier: "com.example.app", streamID: 1)
        await orchestrator.registerStream(bundleIdentifier: "com.example.app", streamID: 2)
        await orchestrator.registerStream(bundleIdentifier: "com.example.app", streamID: 3)
        await orchestrator.forceOwnership(streamID: 1)

        let snapshot = await orchestrator.makeRuntimePolicySnapshot(
            bundleIdentifier: "com.example.app",
            visibleStreamIDs: [1, 2, 3],
            bitrateBudgetBps: 10_000_000,
            activeTargetFPS: 60
        )

        let active = try #require(snapshot.policies.first(where: { $0.streamID == 1 }))
        let passive2 = try #require(snapshot.policies.first(where: { $0.streamID == 2 }))
        let passive3 = try #require(snapshot.policies.first(where: { $0.streamID == 3 }))

        #expect(active.tier == .activeLive)
        #expect(active.targetBitrateBps == 8_000_000)
        #expect(passive2.tier == .passiveSnapshot)
        #expect(passive2.targetBitrateBps == 1_000_000)
        #expect(passive3.tier == .passiveSnapshot)
        #expect(passive3.targetBitrateBps == 1_000_000)
    }

    @Test("Policy applier suppresses no-op and cooldown reconfiguration")
    func policyApplierSuppressesNoopAndCooldown() async {
        let applier = StreamPolicyApplier()
        let context = StreamContext(
            streamID: 101,
            windowID: 1001,
            encoderConfig: .highQuality,
            maxPacketSize: mirageDefaultMaxPacketSize
        )

        let first = MirageStreamPolicy(
            streamID: 101,
            tier: .activeLive,
            targetFPS: 60,
            targetBitrateBps: 24_000_000,
            recoveryProfile: .activeAggressive
        )
        let second = MirageStreamPolicy(
            streamID: 101,
            tier: .activeLive,
            targetFPS: 120,
            targetBitrateBps: 28_000_000,
            recoveryProfile: .activeAggressive
        )

        await applier.apply(policy: first, context: context, requestRecoveryKeyframe: false)
        await applier.apply(policy: first, context: context, requestRecoveryKeyframe: false)
        await applier.apply(policy: second, context: context, requestRecoveryKeyframe: false)

        let diagnostics = await applier.diagnostics(streamID: 101)
        #expect(diagnostics?.appliedUpdates == 1)
        #expect(diagnostics?.suppressedNoOpUpdates == 1)
        #expect(diagnostics?.suppressedCooldownUpdates == 1)
    }

    @Test("Display allocator remains fixed to two slots")
    func displayAllocatorUsesTwoSlots() async {
        let allocator = AppStreamDisplayAllocator()

        #expect(AppStreamDisplayAllocator.maximumDisplayCount == 2)

        await allocator.bindLive(streamID: 70)
        await allocator.bindSnapshot(streamID: 71)
        let snapshot = await allocator.currentSnapshot()
        #expect(snapshot.liveStreamID == 70)
        #expect(snapshot.snapshotStreamID == 71)

        await allocator.unbind(streamID: 70)
        let afterUnbind = await allocator.currentSnapshot()
        #expect(afterUnbind.liveStreamID == nil)
        #expect(afterUnbind.snapshotStreamID == 71)
    }
}
#endif
