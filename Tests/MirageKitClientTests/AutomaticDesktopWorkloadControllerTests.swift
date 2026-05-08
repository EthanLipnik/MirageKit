//
//  AutomaticDesktopWorkloadControllerTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/21/26.
//

@testable import MirageKitClient
import Foundation
import Testing

#if os(macOS)
@Suite("Automatic Desktop Workload Controller")
struct AutomaticDesktopWorkloadControllerTests {
    @Test("Sustained 4K60 host pipeline pressure preserves 60fps by reducing resolution")
    func sustainedFourK60HostPipelinePressurePreserves60FPSByReducingResolution() {
        var controller = MirageAutomaticDesktopWorkloadController()
        let snapshot = pipelineBoundSnapshot(
            width: 3840,
            height: 2160,
            targetFrameRate: 60,
            cadenceFPS: 45
        )

        let action = advanceThroughPipelinePressure(controller: &controller, snapshot: snapshot)

        guard case .reconfigure(let target, _) = action else {
            Issue.record("Expected workload reconfiguration")
            return
        }
        #expect(target == .qhd60)
    }

    @Test("Sustained 4K30 pipeline pressure drops resolution")
    func sustainedFourK30PipelinePressureDropsResolution() {
        var controller = MirageAutomaticDesktopWorkloadController()
        let snapshot = pipelineBoundSnapshot(
            width: 3840,
            height: 2160,
            targetFrameRate: 30,
            cadenceFPS: 20
        )

        let action = advanceThroughPipelinePressure(controller: &controller, snapshot: snapshot)

        guard case .reconfigure(let target, _) = action else {
            Issue.record("Expected workload reconfiguration")
            return
        }
        #expect(target == .qhd30)
    }

    @Test("Dirty transport suppresses workload changes")
    func dirtyTransportSuppressesWorkloadChanges() {
        var controller = MirageAutomaticDesktopWorkloadController()
        var snapshot = pipelineBoundSnapshot(
            width: 3840,
            height: 2160,
            targetFrameRate: 60,
            cadenceFPS: 45
        )
        snapshot.hostSendQueueBytes = 2_000_000

        let action = advanceThroughPipelinePressure(controller: &controller, snapshot: snapshot)

        #expect(action == .none)
    }

    @Test("Resize critical sections suppress workload changes")
    func resizeCriticalSectionsSuppressWorkloadChanges() {
        var controller = MirageAutomaticDesktopWorkloadController()
        let snapshot = pipelineBoundSnapshot(
            width: 3840,
            height: 2160,
            targetFrameRate: 60,
            cadenceFPS: 45
        )

        var action: MirageAutomaticDesktopWorkloadController.Action = .none
        for sample in 0..<8 {
            action = controller.advance(
                snapshot: snapshot,
                resizeCriticalSectionActive: true,
                now: CFAbsoluteTime(sample)
            )
        }

        #expect(action == .none)
    }

    @Test("Workload reconfiguration has a 20 second cooldown")
    func workloadReconfigurationHasCooldown() {
        var controller = MirageAutomaticDesktopWorkloadController()
        let snapshot = pipelineBoundSnapshot(
            width: 3840,
            height: 2160,
            targetFrameRate: 60,
            cadenceFPS: 45
        )

        let firstAction = advanceThroughPipelinePressure(controller: &controller, snapshot: snapshot)
        #expect(firstAction != .none)

        let cooldownAction = advanceThroughPipelinePressure(
            controller: &controller,
            snapshot: snapshot,
            startingAt: 8
        )
        #expect(cooldownAction == .none)

        let afterCooldownAction = advanceThroughPipelinePressure(
            controller: &controller,
            snapshot: snapshot,
            startingAt: 28
        )
        #expect(afterCooldownAction != .none)
    }

    @Test("Client presentation deficit preserves 60fps while lowering resolution")
    func clientPresentationDeficitPreserves60FPSWhileLoweringResolution() {
        var controller = MirageAutomaticDesktopWorkloadController()
        var snapshot = pipelineBoundSnapshot(
            width: 3840,
            height: 2160,
            targetFrameRate: 60,
            cadenceFPS: 60
        )
        snapshot.decodedFPS = 60
        snapshot.submittedFPS = 30
        snapshot.uniqueSubmittedFPS = 30
        snapshot.clientOverwrittenPendingFrames = 2
        snapshot.clientDisplayLayerNotReadyCount = 1
        snapshot.clientPendingFrameAgeMs = 24

        let action = advanceThroughPipelinePressure(controller: &controller, snapshot: snapshot)

        guard case .reconfigure(let target, _) = action else {
            Issue.record("Expected workload reconfiguration")
            return
        }
        #expect(target.targetFrameRate == 60)
        #expect(target.encodedPixelSize.width < 3840)
        #expect(target.encodedPixelSize.height < 2160)
    }

    @Test("ProMotion presentation deficit preserves refresh before reducing FPS")
    func proMotionPresentationDeficitPreservesRefreshBeforeReducingFPS() {
        var controller = MirageAutomaticDesktopWorkloadController()
        var snapshot = pipelineBoundSnapshot(
            width: 2752,
            height: 2064,
            targetFrameRate: 120,
            cadenceFPS: 118
        )
        snapshot.submittedFPS = 92
        snapshot.uniqueSubmittedFPS = 92
        snapshot.clientOverwrittenPendingFrames = 4
        snapshot.clientDisplayLayerNotReadyCount = 2
        snapshot.clientPendingFrameAgeMs = 24

        let action = advanceThroughPipelinePressure(
            controller: &controller,
            snapshot: snapshot,
            minimumTargetFrameRate: 60,
            maximumTargetFrameRate: 120
        )

        guard case .reconfigure(let target, _) = action else {
            Issue.record("Expected workload reconfiguration")
            return
        }
        #expect(target.targetFrameRate == 120)
        #expect(target.encodedPixelSize.width < 2752)
        #expect(target.encodedPixelSize.height < 2064)
    }

    @Test("ProMotion presentation collapse preserves refresh with a lower resolution first")
    func proMotionPresentationCollapsePreservesRefreshWithLowerResolutionFirst() {
        var controller = MirageAutomaticDesktopWorkloadController()
        var snapshot = pipelineBoundSnapshot(
            width: 2752,
            height: 2064,
            targetFrameRate: 120,
            cadenceFPS: 118
        )
        snapshot.submittedFPS = 70
        snapshot.uniqueSubmittedFPS = 70
        snapshot.clientOverwrittenPendingFrames = 8
        snapshot.clientDisplayLayerNotReadyCount = 4
        snapshot.clientPendingFrameAgeMs = 42

        let action = advanceThroughPipelinePressure(
            controller: &controller,
            snapshot: snapshot,
            minimumTargetFrameRate: 60,
            maximumTargetFrameRate: 120
        )

        guard case .reconfigure(let target, _) = action else {
            Issue.record("Expected workload reconfiguration")
            return
        }
        #expect(target.targetFrameRate == 120)
        #expect(target.encodedPixelSize.width < 2752)
        #expect(target.encodedPixelSize.height < 2064)
    }

    @Test("Severe ProMotion presentation collapse downshifts after three samples")
    func severeProMotionPresentationCollapseDownshiftsAfterThreeSamples() {
        var controller = MirageAutomaticDesktopWorkloadController()
        var snapshot = pipelineBoundSnapshot(
            width: 2752,
            height: 2064,
            targetFrameRate: 120,
            cadenceFPS: 118
        )
        snapshot.submittedFPS = 62
        snapshot.uniqueSubmittedFPS = 62
        snapshot.clientPresentedFPS = 62
        snapshot.clientLayerAcceptedFPS = 62
        snapshot.clientOverwrittenPendingFrames = 5
        snapshot.clientDisplayLayerNotReadyCount = 3
        snapshot.clientPendingFrameAgeMs = 48

        var action: MirageAutomaticDesktopWorkloadController.Action = .none
        for sample in 0..<3 {
            action = controller.advance(
                snapshot: snapshot,
                resizeCriticalSectionActive: false,
                minimumTargetFrameRate: 60,
                maximumTargetFrameRate: 120,
                now: CFAbsoluteTime(sample)
            )
        }

        guard case .reconfigure(let target, let reason) = action else {
            Issue.record("Expected fast workload reconfiguration")
            return
        }
        #expect(target.targetFrameRate == 120)
        #expect(target.encodedPixelSize.width < 2752)
        #expect(target.encodedPixelSize.height < 2064)
        #expect(reason.contains("client presentation collapse"))
    }

    @Test("Virtual-display source-bound ProMotion samples do not reconfigure workload")
    func virtualDisplaySourceBoundProMotionSamplesDoNotReconfigureWorkload() {
        var controller = MirageAutomaticDesktopWorkloadController()
        var snapshot = pipelineBoundSnapshot(
            width: 2752,
            height: 2064,
            targetFrameRate: 120,
            cadenceFPS: 70
        )
        snapshot.hostCaptureUsesDisplayRefreshCadence = true
        snapshot.hostCaptureVirtualDisplayTimingSuspect = true

        var action: MirageAutomaticDesktopWorkloadController.Action = .none
        for sample in 0..<8 {
            action = controller.advance(
                snapshot: snapshot,
                resizeCriticalSectionActive: false,
                minimumTargetFrameRate: 60,
                maximumTargetFrameRate: 120,
                now: CFAbsoluteTime(sample)
            )
        }

        #expect(action == .none)
    }

    @Test("ProMotion severe presentation collapse still preserves refresh while reducing resolution")
    func proMotionSeverePresentationCollapsePreservesRefreshWhileReducingResolution() {
        var controller = MirageAutomaticDesktopWorkloadController()
        var snapshot = pipelineBoundSnapshot(
            width: 2752,
            height: 2064,
            targetFrameRate: 120,
            cadenceFPS: 118
        )
        snapshot.submittedFPS = 50
        snapshot.uniqueSubmittedFPS = 50
        snapshot.clientOverwrittenPendingFrames = 8
        snapshot.clientDisplayLayerNotReadyCount = 4
        snapshot.clientPendingFrameAgeMs = 42

        let action = advanceThroughPipelinePressure(
            controller: &controller,
            snapshot: snapshot,
            minimumTargetFrameRate: 60,
            maximumTargetFrameRate: 120
        )

        guard case .reconfigure(let target, _) = action else {
            Issue.record("Expected workload reconfiguration")
            return
        }
        #expect(target.targetFrameRate == 120)
        #expect(target.encodedPixelSize.width < 2752)
        #expect(target.encodedPixelSize.height < 2064)
    }

    @Test("Severe client presentation cadence spikes downshift even near target FPS")
    func severeClientPresentationCadenceSpikesDownshiftEvenNearTargetFPS() {
        var controller = MirageAutomaticDesktopWorkloadController()
        var snapshot = pipelineBoundSnapshot(
            width: 2752,
            height: 2064,
            targetFrameRate: 60,
            cadenceFPS: 60
        )
        snapshot.submittedFPS = 59
        snapshot.uniqueSubmittedFPS = 59
        snapshot.clientFrameIntervalP99Ms = 151

        let action = advanceThroughPipelinePressure(controller: &controller, snapshot: snapshot)

        guard case .reconfigure(let target, _) = action else {
            Issue.record("Expected workload reconfiguration")
            return
        }
        #expect(target.targetFrameRate == 60)
        #expect(target.encodedPixelSize.width < 2752)
        #expect(target.encodedPixelSize.height < 2064)
    }

    @Test("Sustained clean cadence promotes one tier after cooldown")
    func sustainedCleanCadencePromotesOneTierAfterCooldown() {
        var controller = MirageAutomaticDesktopWorkloadController()
        let snapshot = pipelineBoundSnapshot(
            width: 2560,
            height: 1440,
            targetFrameRate: 30,
            cadenceFPS: 30
        )

        var action: MirageAutomaticDesktopWorkloadController.Action = .none
        for sample in 0..<12 {
            let sampleAction = controller.advance(
                snapshot: snapshot,
                resizeCriticalSectionActive: false,
                now: CFAbsoluteTime(sample)
            )
            if sampleAction != .none {
                action = sampleAction
            }
        }

        guard case .reconfigure(let target, _) = action else {
            Issue.record("Expected workload promotion")
            return
        }
        #expect(target == .qhd60)
    }

    @Test("Sustained clean ProMotion custom tier promotes refresh at the same resolution")
    func sustainedCleanProMotionCustomTierPromotesRefreshAtSameResolution() {
        var controller = MirageAutomaticDesktopWorkloadController()
        let snapshot = pipelineBoundSnapshot(
            width: 2752,
            height: 2064,
            targetFrameRate: 60,
            cadenceFPS: 60
        )

        var action: MirageAutomaticDesktopWorkloadController.Action = .none
        for sample in 0..<12 {
            let sampleAction = controller.advance(
                snapshot: snapshot,
                resizeCriticalSectionActive: false,
                minimumTargetFrameRate: 60,
                maximumTargetFrameRate: 120,
                now: CFAbsoluteTime(sample)
            )
            if sampleAction != .none {
                action = sampleAction
            }
        }

        guard case .reconfigure(let target, _) = action else {
            Issue.record("Expected workload promotion")
            return
        }
        #expect(target.encodedPixelSize == CGSize(width: 2752, height: 2064))
        #expect(target.targetFrameRate == 90)
    }

    @Test("Automatic 60fps floor prevents silent downgrade to 30fps")
    func automatic60FPSFloorPreventsSilentDowngradeTo30FPS() {
        var controller = MirageAutomaticDesktopWorkloadController()
        let snapshot = pipelineBoundSnapshot(
            width: 2752,
            height: 2064,
            targetFrameRate: 60,
            cadenceFPS: 25
        )

        let action = advanceThroughPipelinePressure(
            controller: &controller,
            snapshot: snapshot,
            minimumTargetFrameRate: 60
        )

        guard case .reconfigure(let target, _) = action else {
            Issue.record("Expected workload reconfiguration")
            return
        }
        #expect(target.targetFrameRate == 60)
    }

    @Test("Workload reconfiguration is atomic when resize is unavailable")
    func workloadReconfigurationIsAtomicWhenResizeIsUnavailable() {
        let decision = MirageClientService.automaticDesktopWorkloadReconfigurationDecision(
            needsFrameRateChange: true,
            needsResize: true,
            allowsAutomaticResolutionResize: false
        )

        #expect(!decision.shouldChangeFrameRate)
        #expect(!decision.shouldResize)
    }

    private func pipelineBoundSnapshot(
        width: Int,
        height: Int,
        targetFrameRate: Int,
        cadenceFPS: Double
    ) -> MirageClientMetricsSnapshot {
        var snapshot = MirageClientMetricsSnapshot(
            decodedFPS: cadenceFPS,
            receivedFPS: cadenceFPS,
            submittedFPS: cadenceFPS,
            uniqueSubmittedFPS: cadenceFPS,
            decodeHealthy: true,
            hostEncodedFPS: cadenceFPS,
            hostActiveQuality: 0.70,
            hostTargetFrameRate: targetFrameRate,
            hostFrameBudgetMs: 1000.0 / Double(targetFrameRate),
            hostAverageEncodeMs: 10,
            hostCaptureIngressFPS: cadenceFPS,
            hostCaptureFPS: cadenceFPS,
            hostEncodeAttemptFPS: cadenceFPS,
            hostEncodedWidth: width,
            hostEncodedHeight: height,
            hasHostMetrics: true
        )
        snapshot.hostSendQueueBytes = 0
        snapshot.hostSendStartDelayAverageMs = 0
        snapshot.hostSendCompletionAverageMs = 0
        snapshot.hostPacketPacerAverageSleepMs = 0
        snapshot.hostStalePacketDrops = 0
        return snapshot
    }

    private func advanceThroughPipelinePressure(
        controller: inout MirageAutomaticDesktopWorkloadController,
        snapshot: MirageClientMetricsSnapshot,
        minimumTargetFrameRate: Int = 30,
        maximumTargetFrameRate: Int = 60,
        startingAt start: Int = 0
    ) -> MirageAutomaticDesktopWorkloadController.Action {
        var action: MirageAutomaticDesktopWorkloadController.Action = .none
        for sample in start..<(start + 8) {
            let sampleAction = controller.advance(
                snapshot: snapshot,
                resizeCriticalSectionActive: false,
                minimumTargetFrameRate: minimumTargetFrameRate,
                maximumTargetFrameRate: maximumTargetFrameRate,
                now: CFAbsoluteTime(sample)
            )
            if sampleAction != .none {
                action = sampleAction
            }
        }
        return action
    }
}
#endif
