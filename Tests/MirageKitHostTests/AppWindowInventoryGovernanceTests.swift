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
import MirageWire

@Suite("App Window Inventory Governance")
struct AppWindowInventoryGovernanceTests {
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

    @Test("Single visible app stream always stays live")
    func singleVisibleStreamAlwaysStaysLive() async throws {
        let orchestrator = AppStreamRuntimeOrchestrator()
        await orchestrator.registerStream(bundleIdentifier: "com.example.app", streamID: 1)
        await orchestrator.registerStream(bundleIdentifier: "com.example.app", streamID: 2)

        await orchestrator.forceOwnership(streamID: 2, now: 1.0)

        let snapshot = await orchestrator.makeRuntimePolicySnapshot(
            bundleIdentifier: "com.example.app",
            visibleStreamIDs: [1],
            bitrateBudgetBps: 8_000_000,
            activeTargetFPS: 60,
            now: 1.1
        )
        let policy = try #require(snapshot.policies.first)

        #expect(snapshot.activeStreamID == 1)
        #expect(snapshot.nextPolicyTransitionAt == nil)
        #expect(policy.streamID == 1)
        #expect(policy.tier == .activeLive)
        #expect(policy.targetFPS == 60)
        #expect(policy.targetBitrateBps == 8_000_000)
    }

    @Test("Active auxiliary parent selection ignores inactive and hidden streams")
    func activeAuxiliaryParentSelectionIgnoresInactiveAndHiddenStreams() {
        let selected = MirageHostService.preferredActiveVisibleStreamID(
            activeStreams: [
                1: true,
                2: false,
                3: true,
                9: true,
            ],
            visibleStreamIDs: [2, 3, 4]
        )

        #expect(selected == 3)
    }

    @Test("Active auxiliary parent selection returns nil without active visible streams")
    func activeAuxiliaryParentSelectionReturnsNilWithoutActiveVisibleStreams() {
        let selected = MirageHostService.preferredActiveVisibleStreamID(
            activeStreams: [
                1: true,
                2: false,
            ],
            visibleStreamIDs: [2, 3]
        )

        #expect(selected == nil)
    }

    @Test("Policy applier suppresses no-op and cooldown reconfiguration")
    func policyApplierSuppressesNoopAndCooldown() async {
        let applier = StreamPolicyApplier()
        let context = StreamContext(
            streamID: 101,
            windowID: 1001,
            encoderConfig: .highQuality,
            maxPacketSize: MirageWire.mirageDefaultMaxPacketSize
        )
        await context.configureRunningForPolicyApplierTest()

        let first = MirageWire.MirageStreamPolicy(
            streamID: 101,
            tier: .activeLive,
            targetFPS: 60,
            targetBitrateBps: 24_000_000
        )
        let second = MirageWire.MirageStreamPolicy(
            streamID: 101,
            tier: .activeLive,
            targetFPS: 120,
            targetBitrateBps: 28_000_000
        )

        try? await context.updateEncoderSettings(colorDepth: nil, bitrate: 10_000_000)

        await applier.apply(policy: first, context: context, requestRecoveryKeyframe: false)
        #expect(await context.encoderSettings.bitrate == 24_000_000)

        await applier.apply(policy: first, context: context, requestRecoveryKeyframe: false)
        await applier.apply(policy: second, context: context, requestRecoveryKeyframe: false)
        #expect(await context.encoderSettings.bitrate == 24_000_000)
    }
}

private extension StreamContext {
    func configureRunningForPolicyApplierTest() {
        isRunning = true
    }
}
#endif
