//
//  AppWindowInventoryGovernanceTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/27/26.
//
//  App-streaming runtime policy tests.
//

@testable import MirageKitHost
import Foundation
import MirageKit
import Testing

#if os(macOS)
@Suite("App Streaming Governance")
struct AppWindowInventoryGovernanceTests {
    @Test("Ownership gate ignores passive/noisy signals")
    func ownershipGateIgnoresPassiveSignals() async {
        let gate = InputOwnershipGate()

        let moved = MirageInputEvent.mouseMoved(MirageMouseEvent(location: .zero))
        let flags = MirageInputEvent.flagsChanged([])

        #expect(await gate.considerSignal(streamID: 1, event: moved, hostKeyWindowEligible: true) == false)
        #expect(await gate.considerSignal(streamID: 1, event: flags, hostKeyWindowEligible: true) == false)
    }

    @Test("Ownership switches require host key-window eligibility")
    func ownershipSwitchRequiresHostKeyWindowEligibility() async {
        let gate = InputOwnershipGate()
        let click = MirageInputEvent.mouseDown(MirageMouseEvent(location: .zero))

        #expect(await gate.considerSignal(streamID: 11, event: click, hostKeyWindowEligible: false) == false)
        #expect(await gate.considerSignal(streamID: 11, event: click, hostKeyWindowEligible: true) == true)
    }

    @Test("Ownership hold window bounds rapid cross-stream switching")
    func ownershipHoldWindowBoundsRapidSwitching() async {
        let gate = InputOwnershipGate()
        let click = MirageInputEvent.mouseDown(MirageMouseEvent(location: .zero))

        #expect(await gate.considerSignal(streamID: 1, event: click, hostKeyWindowEligible: true) == true)
        #expect(await gate.considerSignal(streamID: 2, event: click, hostKeyWindowEligible: true) == false)
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

    @Test("Coordinator assigns one active live stream and passive snapshot tiers")
    func coordinatorAssignsSingleActiveTier() async {
        let coordinator = AppStreamCoordinator()
        let streamIDs = Array(1 ... 8)
        for streamID in streamIDs {
            await coordinator.registerStream(bundleIdentifier: "com.example.app", streamID: StreamID(streamID))
        }

        await coordinator.forceActiveStream(streamID: 3)
        let plan = await coordinator.makeSessionPlan(
            bundleIdentifier: "com.example.app",
            visibleStreamIDs: streamIDs.map(StreamID.init),
            bitrateBudgetBps: 80_000_000
        )

        #expect(plan.activeStreamID == 3)
        #expect(plan.streamPlans.count == 8)
        #expect(plan.streamPlans.filter { $0.tier == .activeLive }.count == 1)
        #expect(plan.streamPlans.filter { $0.tier == .passiveSnapshot }.count == 7)

        let passiveFPS = Set(plan.streamPlans
            .filter { $0.tier == .passiveSnapshot }
            .map(\.targetFrameRate))
        #expect(passiveFPS.count == 1)
        #expect(passiveFPS.first == 1)
    }

    @Test("Live pipeline suppresses no-op reapply within guard windows")
    func livePipelineSuppressesNoOpReapply() async {
        let pipeline = LiveWindowPipeline()
        let context = StreamContext(
            streamID: 101,
            windowID: 1001,
            encoderConfig: .highQuality,
            maxPacketSize: mirageDefaultMaxPacketSize
        )

        await pipeline.apply(
            streamID: 101,
            context: context,
            targetFrameRate: 60,
            targetBitrateBps: 24_000_000,
            requestRecoveryKeyframe: false
        )
        await pipeline.apply(
            streamID: 101,
            context: context,
            targetFrameRate: 60,
            targetBitrateBps: 24_000_000,
            requestRecoveryKeyframe: false
        )

        let state = await pipeline.debugState(streamID: 101)
        #expect(state?.frameRate == 60)
        #expect(state?.bitrateBps == 24_000_000)
        #expect(state?.appliedFrameRateUpdates == 1)
        #expect(state?.appliedBitrateUpdates == 1)
    }

    @Test("Snapshot pipeline suppresses no-op reapply within guard windows")
    func snapshotPipelineSuppressesNoOpReapply() async {
        let pipeline = SnapshotWindowPipeline()
        let context = StreamContext(
            streamID: 102,
            windowID: 1002,
            encoderConfig: .highQuality,
            maxPacketSize: mirageDefaultMaxPacketSize
        )

        await pipeline.apply(
            streamID: 102,
            context: context,
            targetFrameRate: 2,
            targetBitrateBps: 4_000_000
        )
        await pipeline.apply(
            streamID: 102,
            context: context,
            targetFrameRate: 2,
            targetBitrateBps: 4_000_000
        )

        let state = await pipeline.debugState(streamID: 102)
        #expect(state?.frameRate == 2)
        #expect(state?.bitrateBps == 4_000_000)
        #expect(state?.appliedFrameRateUpdates == 1)
        #expect(state?.appliedBitrateUpdates == 1)
    }
}
#endif
