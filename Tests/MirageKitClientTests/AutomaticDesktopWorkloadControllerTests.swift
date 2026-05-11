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
    @Test("Sustained 4K60 host pipeline pressure preserves 60fps by reducing encoded pixels")
    func sustainedFourK60HostPipelinePressurePreserves60FPSByReducingResolution() {
        var controller = MirageAutomaticDesktopWorkloadController()
        let snapshot = pipelineBoundSnapshot(
            width: 3840,
            height: 2160,
            targetFrameRate: 60,
            cadenceFPS: 45
        )

        let action = advanceThroughPipelinePressure(
            controller: &controller,
            snapshot: snapshot,
            adaptivePriority: .prioritizeSmoothness
        )

        guard case .reconfigure(let target, _) = action else {
            Issue.record("Expected workload reconfiguration")
            return
        }
        #expect(target.targetFrameRate == 60)
        #expect(target.encodedPixelSize.width < 3840)
        #expect(target.encodedPixelSize.height < 2160)
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

        let action = advanceThroughPipelinePressure(
            controller: &controller,
            snapshot: snapshot,
            minimumTargetFrameRate: 60
        )

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

    @Test("Client presentation deficit at 60fps preserve priority reduces encoded pixels")
    func clientPresentationDeficitAt60FPSPreservePriorityReducesEncodedPixels() {
        var controller = MirageAutomaticDesktopWorkloadController()
        var snapshot = pipelineBoundSnapshot(
            width: 3840,
            height: 2160,
            targetFrameRate: 60,
            cadenceFPS: 60
        )
        snapshot.decodedFPS = 60
        snapshot.layerEnqueueFPS = 30
        snapshot.uniqueLayerEnqueueFPS = 30
        snapshot.clientVisibleFrameFPS = 30
        snapshot.clientOverwrittenPendingFrames = 2
        snapshot.clientDisplayLayerNotReadyCount = 1
        snapshot.clientPendingFrameAgeMs = 24

        let action = advanceThroughPipelinePressure(
            controller: &controller,
            snapshot: snapshot,
            minimumTargetFrameRate: 60
        )

        guard case .reconfigure(let target, let reason) = action else {
            Issue.record("Expected client-pressure workload reconfiguration")
            return
        }
        #expect(target.targetFrameRate == 60)
        #expect(target.encodedPixelSize.width < 3840)
        #expect(target.encodedPixelSize.height < 2160)
        #expect(reason.contains("presentationBound"))
    }

    @Test("Report-like 60fps presentation bound preserve priority reduces encoded pixels")
    func reportLike60FPSPresentationBoundPreservePriorityReducesEncodedPixels() {
        var controller = MirageAutomaticDesktopWorkloadController()
        var snapshot = pipelineBoundSnapshot(
            width: 2448,
            height: 1408,
            targetFrameRate: 60,
            cadenceFPS: 60
        )
        snapshot.decodedFPS = 60
        snapshot.layerEnqueueFPS = 45
        snapshot.uniqueLayerEnqueueFPS = 45
        snapshot.clientVisibleFrameFPS = 45
        snapshot.clientOverwrittenPendingFrames = 4
        snapshot.clientDisplayLayerNotReadyCount = 3
        snapshot.clientPendingFrameAgeMs = 72

        let action = advanceThroughPipelinePressure(
            controller: &controller,
            snapshot: snapshot,
            minimumTargetFrameRate: 60,
            adaptivePriority: .preserveResolutionAndBitrate
        )

        guard case .reconfigure(let target, let reason) = action else {
            Issue.record("Expected report-like presentation-bound workload reconfiguration")
            return
        }
        #expect(target.targetFrameRate == 60)
        #expect(target.encodedPixelSize.width < 2448)
        #expect(target.encodedPixelSize.height < 1408)
        #expect(reason.contains("presentationBound"))
    }

    @Test("Smoothness priority severe 60fps client collapse can reduce encoded size")
    func smoothnessPrioritySevere60FPSClientCollapseCanReduceEncodedSize() {
        var controller = MirageAutomaticDesktopWorkloadController()
        var snapshot = pipelineBoundSnapshot(
            width: 3840,
            height: 2160,
            targetFrameRate: 60,
            cadenceFPS: 60
        )
        snapshot.decodedFPS = 60
        snapshot.layerEnqueueFPS = 28
        snapshot.uniqueLayerEnqueueFPS = 28
        snapshot.clientVisibleFrameFPS = 28
        snapshot.clientOverwrittenPendingFrames = 4
        snapshot.clientDisplayLayerNotReadyCount = 3
        snapshot.clientPendingFrameAgeMs = 72

        let action = advanceThroughPipelinePressure(
            controller: &controller,
            snapshot: snapshot,
            minimumTargetFrameRate: 60,
            adaptivePriority: .prioritizeSmoothness
        )

        guard case .reconfigure(let target, let reason) = action else {
            Issue.record("Expected severe client collapse reconfiguration")
            return
        }
        #expect(target.targetFrameRate == 60)
        #expect(target.encodedPixelSize.width < 3840)
        #expect(target.encodedPixelSize.height < 2160)
        #expect(reason.contains("client presentation collapse"))
    }

    @Test("Presentation-bound preserve priority restores reduced resolution toward desktop baseline")
    func presentationBoundPreservePriorityRestoresReducedResolutionTowardDesktopBaseline() {
        var controller = MirageAutomaticDesktopWorkloadController()
        var snapshot = pipelineBoundSnapshot(
            width: 736,
            height: 416,
            targetFrameRate: 60,
            cadenceFPS: 65
        )
        snapshot.decodedFPS = 65
        snapshot.layerEnqueueFPS = 55
        snapshot.uniqueLayerEnqueueFPS = 55
        snapshot.clientVisibleFrameFPS = 55
        snapshot.clientOverwrittenPendingFrames = 4
        snapshot.clientDisplayLayerNotReadyCount = 3
        snapshot.clientPendingFrameAgeMs = 72

        let preferredMaximumTier = MirageAutomaticDesktopWorkloadTier(
            encodedPixelSize: CGSize(width: 2448, height: 1408),
            targetFrameRate: 60
        )
        let action = advanceThroughPipelinePressure(
            controller: &controller,
            snapshot: snapshot,
            minimumTargetFrameRate: 60,
            maximumTargetFrameRate: 60,
            adaptivePriority: .preserveResolutionAndBitrate,
            preferredMaximumTier: preferredMaximumTier
        )

        guard case .reconfigure(let target, let reason) = action else {
            Issue.record("Expected resolution restoration")
            return
        }
        #expect(target.targetFrameRate == 60)
        #expect(snapshot.bottleneckKind == .presentationBound)
        #expect(target.encodedPixelSize.width > 736)
        #expect(target.encodedPixelSize.height > 416)
        #expect(target.pixelRate <= preferredMaximumTier.pixelRate)
        #expect(reason.contains("resolution restoration"))
    }

    @Test("Clean variable ProMotion cadence above floor does not reconfigure")
    func cleanVariableProMotionCadenceAboveFloorDoesNotReconfigure() {
        var controller = MirageAutomaticDesktopWorkloadController()
        let snapshot = pipelineBoundSnapshot(
            width: 2752,
            height: 2064,
            targetFrameRate: 120,
            cadenceFPS: 78
        )

        let action = advanceThroughPipelinePressure(
            controller: &controller,
            snapshot: snapshot,
            minimumTargetFrameRate: 60,
            maximumTargetFrameRate: 120,
            minimumHealthyFrameRate: 60
        )

        #expect(action == .none)
    }

    @Test("ProMotion presentation deficit reduces encoded pixels before lowering FPS")
    func proMotionPresentationDeficitReducesEncodedPixelsBeforeLoweringFPS() {
        var controller = MirageAutomaticDesktopWorkloadController()
        var snapshot = pipelineBoundSnapshot(
            width: 2752,
            height: 2064,
            targetFrameRate: 120,
            cadenceFPS: 118
        )
        snapshot.layerEnqueueFPS = 92
        snapshot.uniqueLayerEnqueueFPS = 92
        snapshot.clientVisibleFrameFPS = 92
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

    @Test("Adaptive streaming controller emits an encoder-only workload vector")
    func adaptiveStreamingControllerEmitsEncoderOnlyWorkloadVector() {
        var controller = MirageAdaptiveStreamingController()
        var snapshot = pipelineBoundSnapshot(
            width: 2752,
            height: 2064,
            targetFrameRate: 120,
            cadenceFPS: 118
        )
        snapshot.layerEnqueueFPS = 70
        snapshot.uniqueLayerEnqueueFPS = 70
        snapshot.clientVisibleFrameFPS = 70
        snapshot.clientOverwrittenPendingFrames = 8
        snapshot.clientDisplayLayerNotReadyCount = 4
        snapshot.clientPendingFrameAgeMs = 42

        var action: MirageAdaptiveStreamingController.Action = .none
        for sample in 0..<8 {
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

        guard case .reconfigure(let vector, _) = action else {
            Issue.record("Expected adaptive streaming workload vector")
            return
        }
        #expect(vector.phase == .encoderOnlyRelief)
        #expect(vector.trigger == .clientPresentationPressure)
        #expect(vector.targetFrameRate == 120)
        #expect(vector.encodedPixelRatio < 1)
        #expect(vector.qualityMultiplier < 1)
    }

    @Test("Adaptive streaming metrics expose active workload vector")
    func adaptiveStreamingMetricsExposeActiveWorkloadVector() {
        let store = MirageClientMetricsStore()
        let currentTier = MirageAutomaticDesktopWorkloadTier(
            encodedPixelSize: CGSize(width: 2752, height: 2064),
            targetFrameRate: 120
        )
        let targetTier = MirageAutomaticDesktopWorkloadTier(
            encodedPixelSize: CGSize(width: 2304, height: 1728),
            targetFrameRate: 120
        )
        let vector = MirageWorkloadVector(
            currentTier: currentTier,
            targetTier: targetTier,
            phase: .encoderOnlyRelief,
            trigger: .clientPresentationPressure
        )

        store.updateAdaptiveStreamingState(
            streamID: 77,
            vector: vector,
            decision: "client presentation collapse"
        )
        let denialCount = store.recordTopologyMutationDenied(streamID: 77)

        let snapshot = store.snapshot(for: 77)
        #expect(snapshot?.adaptiveStreamingRecoveryPhase == .encoderOnlyRelief)
        #expect(snapshot?.adaptiveStreamingTrigger == .clientPresentationPressure)
        #expect(snapshot?.adaptiveStreamingDecision == "client presentation collapse")
        #expect(snapshot?.adaptiveStreamingTargetWidth == 2304)
        #expect(snapshot?.adaptiveStreamingTargetHeight == 1728)
        #expect(snapshot?.adaptiveStreamingTargetFrameRate == 120)
        #expect((snapshot?.adaptiveStreamingEncodedPixelRatio ?? 1) < 1)
        #expect(denialCount == 1)
        #expect(snapshot?.topologyMutationDenialCount == 1)
    }

    @Test("Smoothness priority preserves refresh with a lower resolution first")
    func smoothnessPriorityPreservesRefreshWithLowerResolutionFirst() {
        var controller = MirageAutomaticDesktopWorkloadController()
        var snapshot = pipelineBoundSnapshot(
            width: 2752,
            height: 2064,
            targetFrameRate: 120,
            cadenceFPS: 118
        )
        snapshot.layerEnqueueFPS = 70
        snapshot.uniqueLayerEnqueueFPS = 70
        snapshot.clientVisibleFrameFPS = 70
        snapshot.clientOverwrittenPendingFrames = 8
        snapshot.clientDisplayLayerNotReadyCount = 4
        snapshot.clientPendingFrameAgeMs = 42

        let action = advanceThroughPipelinePressure(
            controller: &controller,
            snapshot: snapshot,
            minimumTargetFrameRate: 60,
            maximumTargetFrameRate: 120,
            adaptivePriority: .prioritizeSmoothness
        )

        guard case .reconfigure(let target, _) = action else {
            Issue.record("Expected workload reconfiguration")
            return
        }
        #expect(target.targetFrameRate == 120)
        #expect(target.encodedPixelSize.width < 2752)
        #expect(target.encodedPixelSize.height < 2064)
    }

    @Test("Severe ProMotion presentation collapse preserves refresh and reduces encoded pixels")
    func severeProMotionPresentationCollapsePreservesRefreshAndReducesEncodedPixels() {
        var controller = MirageAutomaticDesktopWorkloadController()
        var snapshot = pipelineBoundSnapshot(
            width: 2752,
            height: 2064,
            targetFrameRate: 120,
            cadenceFPS: 118
        )
        snapshot.layerEnqueueFPS = 62
        snapshot.uniqueLayerEnqueueFPS = 62
        snapshot.clientVisibleFrameFPS = 62
        snapshot.clientOverwrittenPendingFrames = 5
        snapshot.clientDisplayLayerNotReadyCount = 3
        snapshot.clientPendingFrameAgeMs = 48

        let action = advanceThroughPipelinePressure(
            controller: &controller,
            snapshot: snapshot,
            minimumTargetFrameRate: 60,
            maximumTargetFrameRate: 120
        )

        guard case .reconfigure(let target, let reason) = action else {
            Issue.record("Expected workload reconfiguration")
            return
        }
        #expect(target.targetFrameRate == 120)
        #expect(target.encodedPixelSize.width < 2752)
        #expect(target.encodedPixelSize.height < 2064)
        #expect(reason.contains("client presentation collapse"))
    }

    @Test("Zero-FPS client recovery collapse reduces encoded pixels before lowering FPS")
    func zeroFPSClientRecoveryCollapseReducesEncodedPixelsBeforeLoweringFPS() {
        var controller = MirageAutomaticDesktopWorkloadController()
        var snapshot = pipelineBoundSnapshot(
            width: 2752,
            height: 2064,
            targetFrameRate: 120,
            cadenceFPS: 120
        )
        snapshot.receivedFPS = 0
        snapshot.decodedFPS = 0
        snapshot.layerEnqueueFPS = 0
        snapshot.uniqueLayerEnqueueFPS = 0
        snapshot.clientRendererEnqueueFPS = 0
        snapshot.clientUniqueRendererEnqueueFPS = 0
        snapshot.clientVisibleFrameFPS = 0
        snapshot.clientUniqueDeliveredSourceFrameFPS = 0
        snapshot.decodeHealthy = false
        snapshot.clientReceivedWorstGapMs = 556
        snapshot.clientIncomingMediaBatchIntervalMaxMs = 556

        let action = advanceThroughPipelinePressure(
            controller: &controller,
            snapshot: snapshot,
            minimumTargetFrameRate: 60,
            maximumTargetFrameRate: 120
        )

        guard case .reconfigure(let target, let reason) = action else {
            Issue.record("Expected workload reconfiguration")
            return
        }
        #expect(target.targetFrameRate == 120)
        #expect(target.encodedPixelSize.width < 2752)
        #expect(target.encodedPixelSize.height < 2064)
        #expect(reason.contains("client presentation collapse"))
    }

    @Test("Follow-up 60fps decode collapse reduces encoded pixels quickly")
    func followUp60FPSDecodeCollapseReducesEncodedPixelsQuickly() {
        var controller = MirageAutomaticDesktopWorkloadController()
        let initialCollapse = decodeCollapseSnapshot(
            width: 2752,
            height: 2064,
            targetFrameRate: 120
        )

        let firstAction = advanceThroughPipelinePressure(
            controller: &controller,
            snapshot: initialCollapse,
            minimumTargetFrameRate: 60,
            maximumTargetFrameRate: 120
        )
        #expect(firstAction != .none)

        let followUpCollapse = decodeCollapseSnapshot(
            width: 2752,
            height: 2064,
            targetFrameRate: 60
        )

        var action: MirageAutomaticDesktopWorkloadController.Action = .none
        for sample in 8...12 {
            let sampleAction = controller.advance(
                snapshot: followUpCollapse,
                resizeCriticalSectionActive: false,
                minimumTargetFrameRate: 60,
                maximumTargetFrameRate: 120,
                now: CFAbsoluteTime(sample)
            )
            if sampleAction != .none {
                action = sampleAction
            }
        }

        guard case .reconfigure(let target, let reason) = action else {
            Issue.record("Expected follow-up encoded-pixel reduction")
            return
        }
        #expect(target.targetFrameRate == 60)
        #expect(target.encodedPixelSize.width < 2752)
        #expect(target.encodedPixelSize.height < 2064)
        #expect(reason.contains("client presentation collapse"))
    }

    @Test("Virtual-display source-bound ProMotion samples reduce encoded pixels before lowering FPS")
    func virtualDisplaySourceBoundProMotionSamplesReduceEncodedPixelsBeforeLoweringFPS() {
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
                adaptivePriority: .preserveResolutionAndBitrate,
                now: CFAbsoluteTime(sample)
            )
        }

        guard case .reconfigure(let target, _) = action else {
            Issue.record("Expected source-bound workload reconfiguration")
            return
        }
        #expect(target.targetFrameRate == 120)
        #expect(target.encodedPixelSize.width < 2752)
        #expect(target.encodedPixelSize.height < 2064)
    }

    @Test("Smoothness priority severe presentation collapse preserves refresh while reducing resolution")
    func smoothnessPrioritySeverePresentationCollapsePreservesRefreshWhileReducingResolution() {
        var controller = MirageAutomaticDesktopWorkloadController()
        var snapshot = pipelineBoundSnapshot(
            width: 2752,
            height: 2064,
            targetFrameRate: 120,
            cadenceFPS: 118
        )
        snapshot.layerEnqueueFPS = 50
        snapshot.uniqueLayerEnqueueFPS = 50
        snapshot.clientVisibleFrameFPS = 50
        snapshot.clientOverwrittenPendingFrames = 8
        snapshot.clientDisplayLayerNotReadyCount = 4
        snapshot.clientPendingFrameAgeMs = 42

        let action = advanceThroughPipelinePressure(
            controller: &controller,
            snapshot: snapshot,
            minimumTargetFrameRate: 60,
            maximumTargetFrameRate: 120,
            adaptivePriority: .prioritizeSmoothness
        )

        guard case .reconfigure(let target, _) = action else {
            Issue.record("Expected workload reconfiguration")
            return
        }
        #expect(target.targetFrameRate == 120)
        #expect(target.encodedPixelSize.width < 2752)
        #expect(target.encodedPixelSize.height < 2064)
    }

    @Test("Smoothness priority client failure below floor recovers without dropping refresh")
    func smoothnessPriorityClientFailureBelowFloorRecoversWithoutDroppingRefresh() {
        var controller = MirageAutomaticDesktopWorkloadController()
        var snapshot = pipelineBoundSnapshot(
            width: 2752,
            height: 2064,
            targetFrameRate: 120,
            cadenceFPS: 118
        )
        snapshot.layerEnqueueFPS = 50
        snapshot.uniqueLayerEnqueueFPS = 50
        snapshot.clientVisibleFrameFPS = 50
        snapshot.clientOverwrittenPendingFrames = 4
        snapshot.clientDisplayLayerNotReadyCount = 2
        snapshot.clientPendingFrameAgeMs = 48

        let action = advanceThroughPipelinePressure(
            controller: &controller,
            snapshot: snapshot,
            minimumTargetFrameRate: 60,
            maximumTargetFrameRate: 120,
            minimumHealthyFrameRate: 60,
            adaptivePriority: .prioritizeSmoothness
        )

        guard case .reconfigure(let target, _) = action else {
            Issue.record("Expected workload reconfiguration")
            return
        }
        #expect(target.targetFrameRate == 120)
        #expect(target.encodedPixelSize.width < 2752)
        #expect(target.encodedPixelSize.height < 2064)
    }

    @Test("Sustained presentation spikes near 60fps reduce encoded pixels without lowering FPS")
    func sustainedPresentationSpikesNear60FPSReduceEncodedPixelsWithoutLoweringFPS() {
        var controller = MirageAutomaticDesktopWorkloadController()
        var snapshot = pipelineBoundSnapshot(
            width: 2752,
            height: 2064,
            targetFrameRate: 60,
            cadenceFPS: 60
        )
        snapshot.layerEnqueueFPS = 59
        snapshot.uniqueLayerEnqueueFPS = 59
        snapshot.clientVisibleFrameFPS = 59
        snapshot.clientFrameIntervalP99Ms = 151

        let action = advanceThroughPipelinePressure(
            controller: &controller,
            snapshot: snapshot,
            minimumTargetFrameRate: 60
        )

        guard case .reconfigure(let target, _) = action else {
            Issue.record("Expected sustained presentation jitter workload reconfiguration")
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

    @Test("Sustained clean custom 60fps downscale promotes toward a higher tier")
    func sustainedCleanCustom60FPSDownscalePromotesTowardHigherTier() {
        var controller = MirageAutomaticDesktopWorkloadController()
        let snapshot = pipelineBoundSnapshot(
            width: 2080,
            height: 1200,
            targetFrameRate: 60,
            cadenceFPS: 60
        )

        var action: MirageAutomaticDesktopWorkloadController.Action = .none
        for sample in 0..<12 {
            let sampleAction = controller.advance(
                snapshot: snapshot,
                resizeCriticalSectionActive: false,
                minimumTargetFrameRate: 60,
                maximumTargetFrameRate: 60,
                now: CFAbsoluteTime(sample)
            )
            if sampleAction != .none {
                action = sampleAction
            }
        }

        guard case .reconfigure(let target, _) = action else {
            Issue.record("Expected custom-tier workload promotion")
            return
        }
        #expect(target == .qhd60)
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

    @Test("Frame-rate reconfiguration still applies when stream scale plan is unavailable")
    func frameRateReconfigurationStillAppliesWhenStreamScalePlanIsUnavailable() {
        let decision = MirageClientService.automaticDesktopWorkloadReconfigurationDecision(
            needsFrameRateChange: true,
            needsStreamScaleChange: true,
            hasStreamScalePlan: false
        )

        #expect(decision.shouldChangeFrameRate)
        #expect(!decision.shouldChangeStreamScale)
    }

    @Test("Automatic desktop workload computes stream scale without changing display size")
    func automaticDesktopWorkloadComputesStreamScaleWithoutChangingDisplaySize() {
        let downscale = MirageClientService.automaticDesktopStreamScaleReconfigurationPlan(
            targetEncodedPixelSize: CGSize(width: 2096, height: 1200),
            baseDisplayPixelSize: CGSize(width: 2448, height: 1408)
        )
        #expect(downscale?.streamScale != nil)
        #expect((downscale?.streamScale ?? 1) < 1)
        #expect((downscale?.encodedPixelSize.width ?? 0) <= 2096)
        #expect((downscale?.encodedPixelSize.height ?? 0) <= 1200)

        let reportScale = MirageClientService.automaticDesktopStreamScaleReconfigurationPlan(
            targetEncodedPixelSize: CGSize(width: 752, height: 432),
            baseDisplayPixelSize: CGSize(width: 2448, height: 1408)
        )
        #expect(reportScale?.encodedPixelSize == CGSize(width: 752, height: 432))
        #expect(reportScale?.encodedPixelSize != CGSize(width: 736, height: 416))

        let fullQuality = MirageClientService.automaticDesktopStreamScaleReconfigurationPlan(
            targetEncodedPixelSize: CGSize(width: 2560, height: 1440),
            baseDisplayPixelSize: CGSize(width: 2448, height: 1408)
        )
        #expect(fullQuality?.streamScale == 1.0)
        #expect(fullQuality?.encodedPixelSize == CGSize(width: 2448, height: 1408))
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
            layerEnqueueFPS: cadenceFPS,
            uniqueLayerEnqueueFPS: cadenceFPS,
            clientVisibleFrameFPS: cadenceFPS,
            clientVisibleFrameCadenceKnown: true,
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

    private func decodeCollapseSnapshot(
        width: Int,
        height: Int,
        targetFrameRate: Int
    ) -> MirageClientMetricsSnapshot {
        var snapshot = pipelineBoundSnapshot(
            width: width,
            height: height,
            targetFrameRate: targetFrameRate,
            cadenceFPS: 44
        )
        snapshot.hostCaptureIngressFPS = 120.4
        snapshot.hostCaptureFPS = 120.4
        snapshot.hostEncodeAttemptFPS = 119.9
        snapshot.hostEncodedFPS = targetFrameRate >= 90 ? 120 : 81.2
        snapshot.receivedFPS = 44
        snapshot.decodedFPS = 44
        snapshot.layerEnqueueFPS = 44
        snapshot.uniqueLayerEnqueueFPS = 44
        snapshot.clientRendererEnqueueFPS = 44
        snapshot.clientUniqueRendererEnqueueFPS = 44
        snapshot.clientVisibleFrameFPS = 42
        snapshot.clientUniqueDeliveredSourceFrameFPS = 42
        snapshot.decodeHealthy = false
        snapshot.clientFrameIntervalP99Ms = 83
        snapshot.clientVisibleFrameIntervalP99Ms = 83
        snapshot.clientReceivedWorstGapMs = 640
        return snapshot
    }

    private func advanceThroughPipelinePressure(
        controller: inout MirageAutomaticDesktopWorkloadController,
        snapshot: MirageClientMetricsSnapshot,
        minimumTargetFrameRate: Int = 30,
        maximumTargetFrameRate: Int = 60,
        minimumHealthyFrameRate: Int? = nil,
        adaptivePriority: MirageAdaptiveQualityPriority = .preserveResolutionAndBitrate,
        preferredMaximumTier: MirageAutomaticDesktopWorkloadTier? = nil,
        startingAt start: Int = 0
    ) -> MirageAutomaticDesktopWorkloadController.Action {
        var action: MirageAutomaticDesktopWorkloadController.Action = .none
        for sample in start..<(start + 8) {
            let sampleAction = controller.advance(
                snapshot: snapshot,
                resizeCriticalSectionActive: false,
                minimumTargetFrameRate: minimumTargetFrameRate,
                maximumTargetFrameRate: maximumTargetFrameRate,
                minimumHealthyFrameRate: minimumHealthyFrameRate,
                adaptivePriority: adaptivePriority,
                preferredMaximumTier: preferredMaximumTier,
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
