//
//  HostStreamTransportControllerTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/14/26.
//

#if os(macOS)
import CoreFoundation
@testable import MirageKit
@testable import MirageKitHost
import Testing
import MirageWire

@Suite("Host Stream Transport Controller")
struct HostStreamTransportControllerTests {
    @Test("Receiver recovery feedback returns a transport hold decision")
    func receiverRecoveryFeedbackReturnsTransportHoldDecision() {
        var controller = HostStreamTransportController()

        let decision = controller.update(
            with: feedback(sequence: 1, recoveryState: .keyframeRecovery),
            currentFrameRate: 120,
            now: 10
        )

        #expect(decision?.pressureTrigger == .clear)
    }

    @Test("Receiver backlog pressure reports transport pressure without FPS admission")
    func receiverBacklogPressureReportsTransportPressureWithoutFPSAdmission() {
        var controller = HostStreamTransportController()

        let firstSample = controller.update(
            with: feedback(sequence: 1, targetFPS: 120, reassemblyBacklogFrames: 8),
            currentFrameRate: 120,
            now: 20
        )
        #expect(firstSample == nil)

        let pressure = controller.update(
            with: feedback(sequence: 2, targetFPS: 120, reassemblyBacklogFrames: 8),
            currentFrameRate: 120,
            now: 20.5
        )

        #expect(pressure?.pressureTrigger == .clientReassemblyBacklog)

        let stale = controller.update(
            with: feedback(sequence: 2, targetFPS: 120, reassemblyBacklogFrames: 8),
            currentFrameRate: 120,
            now: 21
        )
        #expect(stale == nil)

        let stable = controller.update(
            with: feedback(sequence: 3, targetFPS: 120),
            currentFrameRate: 120,
            now: 22.6
        )

        #expect(stable == nil)
    }

    @Test("Sustained 120 Hz receiver pressure keeps reporting pressure")
    func sustainedOneTwentyReceiverPressureKeepsReportingPressure() {
        var controller = HostStreamTransportController()

        _ = controller.update(
            with: feedback(sequence: 1, targetFPS: 120, reassemblyBacklogFrames: 8),
            currentFrameRate: 120,
            now: 20
        )
        let firstPressure = controller.update(
            with: feedback(sequence: 2, targetFPS: 120, reassemblyBacklogFrames: 8),
            currentFrameRate: 120,
            now: 20.5
        )
        _ = controller.update(
            with: feedback(sequence: 3, targetFPS: 120, reassemblyBacklogFrames: 8),
            currentFrameRate: 120,
            now: 21
        )
        let persistentPressure = controller.update(
            with: feedback(sequence: 4, targetFPS: 120, reassemblyBacklogFrames: 8),
            currentFrameRate: 120,
            now: 21.5
        )

        #expect(firstPressure?.pressureTrigger == .clientReassemblyBacklog)
        #expect(persistentPressure?.pressureTrigger == .clientReassemblyBacklog)
    }

    @Test("Receiver jitter alone does not produce non-AWDL pressure")
    func receiverJitterAloneDoesNotProduceNonAwdlPressure() {
        var controller = HostStreamTransportController()

        let firstSample = controller.update(
            with: feedback(sequence: 1, targetFPS: 144, jitterP99Ms: 130),
            currentFrameRate: 144,
            now: 30
        )
        let secondSample = controller.update(
            with: feedback(sequence: 2, targetFPS: 144, jitterP99Ms: 130),
            currentFrameRate: 144,
            now: 30.5
        )

        #expect(firstSample == nil)
        #expect(secondSample == nil)
    }

    @Test("AWDL receiver jitter enables pacing")
    func awdlReceiverJitterEnablesPacing() {
        var controller = HostStreamTransportController()

        let firstSample = controller.update(
            with: feedback(sequence: 1, targetFPS: 60, receiverJitterP99Ms: 90),
            currentFrameRate: 60,
            transportPathKind: .awdl,
            mediaPathProfile: .awdlRadio,
            now: 60
        )
        #expect(firstSample == nil)

        let pressure = controller.update(
            with: feedback(sequence: 2, targetFPS: 60, receiverJitterP99Ms: 90),
            currentFrameRate: 60,
            transportPathKind: .awdl,
            mediaPathProfile: .awdlRadio,
            now: 60.5
        )

        #expect(pressure?.pressureTrigger == .clientJitter)
        #expect(pressure?.awdlPacingDeadline == 62.5)
        #expect(pressure?.awdlPacingTrigger == .clientJitter)
        #expect(pressure?.awdlPolicyState == .stressed)
        #expect(pressure?.awdlPolicyTrigger == .jitter)
        #expect(pressure?.awdlSelectedLever == .frameRate)
        #expect(pressure?.awdlTargetFrameRate == 45)
        #expect(pressure?.awdlResolutionScale == nil)
        #expect(pressure?.awdlPlayoutDelayMs == 64)

        let cleared = controller.update(
            with: feedback(sequence: 3, targetFPS: 60),
            currentFrameRate: 60,
            transportPathKind: .awdl,
            mediaPathProfile: .awdlRadio,
            now: 62.6
        )

        #expect(cleared?.awdlPacingDeadline == 0)
        #expect(cleared?.awdlPacingTrigger == .clear)
    }

    @Test("AWDL startup feedback enters first-frame pacing policy")
    func awdlStartupFeedbackEntersFirstFramePacingPolicy() {
        var controller = HostStreamTransportController()

        let decision = controller.update(
            with: feedback(sequence: 1, targetFPS: 60, recoveryState: .postResizeAwaitingFirstFrame),
            currentFrameRate: 60,
            transportPathKind: .awdl,
            mediaPathProfile: .awdlRadio,
            now: 66
        )

        #expect(decision?.pressureTrigger == .clear)
        #expect(decision?.awdlPacingTrigger == .clientRecovery)
        #expect(decision?.awdlPolicyState == .awaitingFirstFrame)
        #expect(decision?.awdlPolicyTrigger == .startup)
        #expect(decision?.awdlTargetFrameRate == 45)
        #expect(decision?.awdlResolutionScale == nil)
    }

    @Test("AWDL P-frame latency enables pacing")
    func awdlPFrameLatencyEnablesPacing() {
        var controller = HostStreamTransportController()

        let firstSample = controller.update(
            with: feedback(sequence: 1, targetFPS: 60, pFrameCompletionLatencyP95Ms: 72),
            currentFrameRate: 60,
            transportPathKind: .awdl,
            mediaPathProfile: .awdlRadio,
            now: 70
        )
        #expect(firstSample == nil)

        let pressure = controller.update(
            with: feedback(sequence: 2, targetFPS: 60, pFrameCompletionLatencyP95Ms: 72),
            currentFrameRate: 60,
            transportPathKind: .awdl,
            mediaPathProfile: .awdlRadio,
            now: 70.5
        )

        #expect(pressure?.pressureTrigger == .clientPFrameLatency)
        #expect(pressure?.awdlPacingDeadline == 72.5)
        #expect(pressure?.awdlPacingTrigger == .clientPFrameLatency)
        #expect(pressure?.awdlPolicyState == .stressed)
        #expect(pressure?.awdlPolicyTrigger == .pFrameLatency)
        #expect(pressure?.awdlResolutionScale == nil)
    }

    @Test("AWDL P-frame latency pacing respects receiver playout target")
    func awdlPFrameLatencyPacingRespectsReceiverPlayoutTarget() {
        var controller = HostStreamTransportController()

        _ = controller.update(
            with: feedback(
                sequence: 1,
                targetFPS: 60,
                pFrameCompletionLatencyP95Ms: 90,
                playoutDelayTargetMs: 120
            ),
            currentFrameRate: 60,
            transportPathKind: .awdl,
            mediaPathProfile: .awdlRadio,
            now: 71
        )
        let smoothed = controller.update(
            with: feedback(
                sequence: 2,
                targetFPS: 60,
                pFrameCompletionLatencyP95Ms: 90,
                playoutDelayTargetMs: 120
            ),
            currentFrameRate: 60,
            transportPathKind: .awdl,
            mediaPathProfile: .awdlRadio,
            now: 71.5
        )

        #expect(smoothed == nil)
        #expect(controller.latestAwdlMediaDecision?.trigger == .stable)

        let firstLateSample = controller.update(
            with: feedback(
                sequence: 3,
                targetFPS: 60,
                pFrameCompletionLatencyP95Ms: 150,
                playoutDelayTargetMs: 120
            ),
            currentFrameRate: 60,
            transportPathKind: .awdl,
            mediaPathProfile: .awdlRadio,
            now: 72
        )
        #expect(firstLateSample == nil)

        let pressure = controller.update(
            with: feedback(
                sequence: 4,
                targetFPS: 60,
                pFrameCompletionLatencyP95Ms: 150,
                playoutDelayTargetMs: 120
            ),
            currentFrameRate: 60,
            transportPathKind: .awdl,
            mediaPathProfile: .awdlRadio,
            now: 72.5
        )

        #expect(pressure?.pressureTrigger == .clientPFrameLatency)
        #expect(pressure?.awdlPolicyTrigger == .pFrameLatency)
    }

    @Test("AWDL sender queue pressure enables pacing before receiver loss")
    func awdlSenderQueuePressureEnablesPacingBeforeReceiverLoss() {
        var controller = HostStreamTransportController()
        let telemetry = senderTelemetry(
            unstartedPFrameCount: 2,
            oldestUnstartedPFrameAgeMs: 40
        )

        let firstSample = controller.update(
            with: feedback(sequence: 1, targetFPS: 60),
            currentFrameRate: 60,
            transportPathKind: .awdl,
            mediaPathProfile: .awdlRadio,
            senderTelemetry: telemetry,
            now: 73
        )
        #expect(firstSample == nil)

        let pressure = controller.update(
            with: feedback(sequence: 2, targetFPS: 60),
            currentFrameRate: 60,
            transportPathKind: .awdl,
            mediaPathProfile: .awdlRadio,
            senderTelemetry: telemetry,
            now: 73.5
        )

        #expect(pressure?.pressureTrigger == .senderQueue)
        #expect(pressure?.awdlPacingTrigger == .senderQueue)
        #expect(pressure?.awdlPacingDeadline == 75.5)

        var nonAwdlController = HostStreamTransportController()
        _ = nonAwdlController.update(
            with: feedback(sequence: 1, targetFPS: 60),
            currentFrameRate: 60,
            mediaPathProfile: .localWiFi,
            senderTelemetry: telemetry,
            now: 74
        )
        let nonAwdlPressure = nonAwdlController.update(
            with: feedback(sequence: 2, targetFPS: 60),
            currentFrameRate: 60,
            mediaPathProfile: .localWiFi,
            senderTelemetry: telemetry,
            now: 74.5
        )
        #expect(nonAwdlPressure == nil)
    }

    @Test("AWDL presentation pressure demotes policy with transport pacing trigger")
    func awdlPresentationPressureDemotesPolicyWithTransportPacingTrigger() {
        var backlogController = HostStreamTransportController()

        let healthyQueue = backlogController.update(
            with: feedback(sequence: 1, presentationQueueDepth: 5, presentationTargetFrames: 5),
            currentFrameRate: 60,
            transportPathKind: .awdl,
            mediaPathProfile: .awdlRadio,
            now: 75
        )
        #expect(healthyQueue == nil)
        #expect(backlogController.latestAwdlMediaDecision?.trigger == .stable)

        _ = backlogController.update(
            with: feedback(sequence: 2, presentationQueueDepth: 9, presentationTargetFrames: 5),
            currentFrameRate: 60,
            transportPathKind: .awdl,
            mediaPathProfile: .awdlRadio,
            now: 75.5
        )
        let backlogDecision = backlogController.update(
            with: feedback(sequence: 3, presentationQueueDepth: 9, presentationTargetFrames: 5),
            currentFrameRate: 60,
            transportPathKind: .awdl,
            mediaPathProfile: .awdlRadio,
            now: 76
        )

        #expect(backlogDecision?.pressureTrigger == .clientPresentationBacklog)
        #expect(backlogDecision?.awdlPacingDeadline == 78)
        #expect(backlogDecision?.awdlPacingTrigger == .clientPresentationBacklog)
        #expect(backlogController.latestAwdlMediaDecision?.state == .stressed)
        #expect(backlogController.latestAwdlMediaDecision?.trigger == .presentationBacklog)
        #expect(backlogDecision?.awdlTargetFrameRate == 45)
        #expect(backlogDecision?.awdlResolutionScale == nil)

        var underfillController = HostStreamTransportController()
        _ = underfillController.update(
            with: feedback(sequence: 1, presentationUnderfillFrames: 2),
            currentFrameRate: 60,
            transportPathKind: .awdl,
            mediaPathProfile: .awdlRadio,
            now: 77
        )
        let underfillDecision = underfillController.update(
            with: feedback(sequence: 2, presentationUnderfillFrames: 2),
            currentFrameRate: 60,
            transportPathKind: .awdl,
            mediaPathProfile: .awdlRadio,
            now: 77.5
        )

        #expect(underfillDecision == nil)
        #expect(underfillController.latestAwdlMediaDecision?.trigger == .stable)

        var fillDeficitController = HostStreamTransportController()
        _ = fillDeficitController.update(
            with: feedback(sequence: 1, presentationFillDeficitFrames: 3),
            currentFrameRate: 60,
            transportPathKind: .awdl,
            mediaPathProfile: .awdlRadio,
            now: 77
        )
        let fillDeficitDecision = fillDeficitController.update(
            with: feedback(sequence: 2, presentationFillDeficitFrames: 3),
            currentFrameRate: 60,
            transportPathKind: .awdl,
            mediaPathProfile: .awdlRadio,
            now: 77.5
        )

        #expect(fillDeficitDecision?.awdlPacingTrigger == .clientPresentationFillDeficit)
        #expect(fillDeficitDecision?.awdlSelectedLever == .playout)
        #expect(fillDeficitController.latestAwdlMediaDecision?.trigger == .presentationFillDeficit)
        #expect(fillDeficitController.latestAwdlMediaDecision?.targetFrameRate == 60)

        var visibleUnderflowController = HostStreamTransportController()
        _ = visibleUnderflowController.update(
            with: feedback(sequence: 1, presentationUnderfillFrames: 2, displayTickNoFrameCount: 3),
            currentFrameRate: 60,
            transportPathKind: .awdl,
            mediaPathProfile: .awdlRadio,
            now: 78
        )
        let visibleUnderflowDecision = visibleUnderflowController.update(
            with: feedback(sequence: 2, presentationUnderfillFrames: 2, displayTickNoFrameCount: 3),
            currentFrameRate: 60,
            transportPathKind: .awdl,
            mediaPathProfile: .awdlRadio,
            now: 78.5
        )

        #expect(visibleUnderflowDecision?.pressureTrigger == .clientPresentationUnderflow)
        #expect(visibleUnderflowDecision?.awdlPacingDeadline == 80.5)
        #expect(visibleUnderflowDecision?.awdlPacingTrigger == .clientPresentationUnderflow)
        #expect(visibleUnderflowController.latestAwdlMediaDecision?.state == .stressed)
        #expect(visibleUnderflowController.latestAwdlMediaDecision?.trigger == .presentationUnderflow)
        #expect(visibleUnderflowDecision?.awdlTargetFrameRate == 45)
        #expect(visibleUnderflowDecision?.awdlResolutionScale == nil)

        var notReadyUnderflowController = HostStreamTransportController()
        _ = notReadyUnderflowController.update(
            with: feedback(sequence: 1, pendingFrameNotReadyDisplayTickCount: 3),
            currentFrameRate: 60,
            transportPathKind: .awdl,
            mediaPathProfile: .awdlRadio,
            now: 81
        )
        let notReadyUnderflowDecision = notReadyUnderflowController.update(
            with: feedback(sequence: 2, pendingFrameNotReadyDisplayTickCount: 3),
            currentFrameRate: 60,
            transportPathKind: .awdl,
            mediaPathProfile: .awdlRadio,
            now: 81.5
        )

        #expect(notReadyUnderflowDecision?.pressureTrigger == .clientPresentationUnderflow)
        #expect(notReadyUnderflowDecision?.awdlPacingTrigger == .clientPresentationUnderflow)
        #expect(notReadyUnderflowController.latestAwdlMediaDecision?.state == .stressed)
        #expect(notReadyUnderflowController.latestAwdlMediaDecision?.trigger == .presentationUnderflow)
        #expect(notReadyUnderflowDecision?.awdlTargetFrameRate == 45)
        #expect(notReadyUnderflowDecision?.awdlResolutionScale == nil)
    }

    @Test("AWDL resolution scale is advertised only for sustained demotion")
    func awdlResolutionScaleIsAdvertisedOnlyForSustainedDemotion() {
        var controller = HostStreamTransportController()

        _ = controller.update(
            with: feedback(sequence: 1, targetFPS: 60, pFrameCompletionLatencyP95Ms: 80, latePFrameCount: 4),
            currentFrameRate: 60,
            transportPathKind: .awdl,
            mediaPathProfile: .awdlRadio,
            now: 80
        )
        let stressed = controller.update(
            with: feedback(sequence: 2, targetFPS: 60, pFrameCompletionLatencyP95Ms: 80, latePFrameCount: 4),
            currentFrameRate: 60,
            transportPathKind: .awdl,
            mediaPathProfile: .awdlRadio,
            now: 80.1
        )
        _ = controller.update(
            with: feedback(sequence: 3, targetFPS: 60, pFrameCompletionLatencyP95Ms: 80, latePFrameCount: 4),
            currentFrameRate: 60,
            transportPathKind: .awdl,
            mediaPathProfile: .awdlRadio,
            now: 80.2
        )
        let demoted = controller.update(
            with: feedback(sequence: 4, targetFPS: 60, pFrameCompletionLatencyP95Ms: 80, latePFrameCount: 4),
            currentFrameRate: 60,
            transportPathKind: .awdl,
            mediaPathProfile: .awdlRadio,
            now: 80.3
        )
        let cadenceDemote = controller.update(
            with: feedback(sequence: 5, targetFPS: 60, pFrameCompletionLatencyP95Ms: 80, latePFrameCount: 4),
            currentFrameRate: 45,
            transportPathKind: .awdl,
            mediaPathProfile: .awdlRadio,
            now: 80.4
        )
        let resolutionDemote = controller.update(
            with: feedback(sequence: 6, targetFPS: 60, pFrameCompletionLatencyP95Ms: 80, latePFrameCount: 4),
            currentFrameRate: 30,
            transportPathKind: .awdl,
            mediaPathProfile: .awdlRadio,
            now: 80.5
        )
        let repeatedResolutionDemote = controller.update(
            with: feedback(sequence: 7, targetFPS: 60, pFrameCompletionLatencyP95Ms: 80, latePFrameCount: 4),
            currentFrameRate: 30,
            transportPathKind: .awdl,
            mediaPathProfile: .awdlRadio,
            now: 80.6
        )
        _ = controller.update(
            with: feedback(sequence: 8, targetFPS: 30),
            currentFrameRate: 30,
            transportPathKind: .awdl,
            mediaPathProfile: .awdlRadio,
            now: 81
        )
        _ = controller.update(
            with: feedback(sequence: 9, targetFPS: 30),
            currentFrameRate: 30,
            transportPathKind: .awdl,
            mediaPathProfile: .awdlRadio,
            now: 81.5
        )
        let restored = controller.update(
            with: feedback(sequence: 10, targetFPS: 30),
            currentFrameRate: 30,
            transportPathKind: .awdl,
            mediaPathProfile: .awdlRadio,
            now: 82.5
        )

        #expect(stressed?.awdlPolicyState == .stressed)
        #expect(stressed?.awdlResolutionScale == nil)
        #expect(demoted?.awdlPolicyState == .demoted)
        #expect(demoted?.awdlTargetFrameRate == 45)
        #expect(demoted?.awdlResolutionScale == nil)
        #expect(cadenceDemote?.awdlTargetFrameRate == 30)
        #expect(cadenceDemote?.awdlResolutionScale == nil)
        #expect(resolutionDemote?.awdlPolicyState == .demoted)
        #expect(resolutionDemote?.awdlResolutionScale == 0.875)
        #expect(repeatedResolutionDemote?.awdlPolicyState == .demoted)
        #expect(repeatedResolutionDemote?.awdlResolutionScale == 0.875)
        #expect(restored?.awdlPolicyState == .steady)
        #expect(restored?.awdlResolutionScale == 1.0)
    }

    @Test("AWDL demoted feedback restores using host requested frame-rate ceiling after sustained stability")
    func awdlDemotedFeedbackRestoresUsingHostRequestedFrameRateCeilingAfterSustainedStability() {
        var controller = HostStreamTransportController()

        for sequence in 1...4 {
            _ = controller.update(
                with: feedback(sequence: UInt64(sequence), targetFPS: 60, receiverJitterP99Ms: 130),
                currentFrameRate: 60,
                requestedFrameRateCeiling: 60,
                transportPathKind: .awdl,
                mediaPathProfile: .awdlRadio,
                now: 90 + Double(sequence) * 0.1
            )
        }
        #expect(controller.latestAwdlMediaDecision?.targetFrameRate == 45)

        let restoring = controller.update(
            with: feedback(sequence: 5, targetFPS: 45),
            currentFrameRate: 45,
            requestedFrameRateCeiling: 60,
            transportPathKind: .awdl,
            mediaPathProfile: .awdlRadio,
            now: 91
        )

        #expect(restoring == nil)

        _ = controller.update(
            with: feedback(sequence: 6, targetFPS: 45),
            currentFrameRate: 45,
            requestedFrameRateCeiling: 60,
            transportPathKind: .awdl,
            mediaPathProfile: .awdlRadio,
            now: 91.5
        )
        let restored = controller.update(
            with: feedback(sequence: 7, targetFPS: 45),
            currentFrameRate: 45,
            requestedFrameRateCeiling: 60,
            transportPathKind: .awdl,
            mediaPathProfile: .awdlRadio,
            now: 92
        )

        #expect(restored?.awdlPolicyTrigger == .stable)
        #expect(restored?.awdlPolicyState == .steady)
        #expect(restored?.awdlTargetFrameRate == 60)
        #expect(restored?.awdlResolutionScale == nil)
    }

    @Test("Receiver transport loss requires sustained samples before pressure")
    func receiverTransportLossRequiresSustainedSamplesBeforePressure() {
        var controller = HostStreamTransportController()

        let firstSample = controller.update(
            with: feedback(sequence: 1, lostFrameCount: 6),
            currentFrameRate: 60,
            now: 40
        )
        let pressure = controller.update(
            with: feedback(sequence: 2, lostFrameCount: 6),
            currentFrameRate: 60,
            now: 40.5
        )

        #expect(firstSample == nil)
        #expect(pressure?.pressureTrigger == .clientTransportLoss)
    }

    @Test("Recovery and keyframe backlog returns hold decision")
    func recoveryAndKeyframeBacklogReturnsHoldDecision() {
        var controller = HostStreamTransportController()

        _ = controller.update(
            with: feedback(sequence: 1, reassemblyBacklogFrames: 8),
            currentFrameRate: 60,
            now: 50
        )
        _ = controller.update(
            with: feedback(sequence: 2, reassemblyBacklogFrames: 8),
            currentFrameRate: 60,
            now: 50.5
        )

        let keyframeBacklog = controller.update(
            with: feedback(sequence: 3, reassemblyBacklogFrames: 12, reassemblyBacklogKeyframes: 1),
            currentFrameRate: 60,
            now: 51
        )

        #expect(keyframeBacklog?.pressureTrigger == .clear)
    }

    private func feedback(
        sequence: UInt64,
        targetFPS: Int = 60,
        lostFrameCount: UInt64 = 0,
        discardedPacketCount: UInt64 = 0,
        jitterP99Ms: Double = 0,
        receiverJitterP99Ms: Double? = nil,
        reassemblyBacklogFrames: Int = 0,
        reassemblyBacklogKeyframes: Int = 0,
        reassemblyBacklogBytes: Int = 0,
        recoveryState: MirageWire.MirageMediaFeedbackRecoveryState = .idle,
        pFrameCompletionLatencyP95Ms: Double? = nil,
        playoutDelayTargetMs: Double? = nil,
        latePFrameCount: UInt64? = nil,
        presentationQueueDepth: Int? = nil,
        presentationTargetFrames: Int? = nil,
        presentationFillDeficitFrames: Int? = nil,
        presentationUnderfillFrames: Int? = nil,
        displayTickNoFrameCount: UInt64? = nil,
        pendingFrameNotReadyDisplayTickCount: UInt64? = nil
    ) -> MirageWire.ReceiverMediaFeedbackMessage {
        MirageWire.ReceiverMediaFeedbackMessage(
            streamID: 1,
            sequence: sequence,
            sentAtUptime: 0,
            targetFPS: targetFPS,
            ackRanges: [],
            lostFrameCount: lostFrameCount,
            discardedPacketCount: discardedPacketCount,
            jitterP95Ms: 0,
            jitterP99Ms: jitterP99Ms,
            queueEstimateFrames: 0,
            reassemblyBacklogFrames: reassemblyBacklogFrames,
            reassemblyBacklogKeyframes: reassemblyBacklogKeyframes,
            reassemblyBacklogBytes: reassemblyBacklogBytes,
            decodeBacklogFrames: 0,
            presentationBacklogFrames: 0,
            decodedFPS: Double(targetFPS),
            receivedFPS: Double(targetFPS),
            rendererAcceptedFPS: Double(targetFPS),
            rendererPresentedFPS: Double(targetFPS),
            recoveryState: recoveryState,
            pFrameCompletionLatencyP50Ms: nil,
            pFrameCompletionLatencyP95Ms: pFrameCompletionLatencyP95Ms,
            pFrameCompletionLatencyMaxMs: nil,
            latePFrameCount: latePFrameCount,
            displayTickNoFrameCount: displayTickNoFrameCount,
            pendingFrameNotReadyDisplayTickCount: pendingFrameNotReadyDisplayTickCount,
            playoutDelayTargetMs: playoutDelayTargetMs,
            presentationQueueDepth: presentationQueueDepth,
            presentationTargetFrames: presentationTargetFrames,
            presentationFillDeficitFrames: presentationFillDeficitFrames,
            presentationUnderfillFrames: presentationUnderfillFrames,
            receiverJitterP99Ms: receiverJitterP99Ms
        )
    }

    private func senderTelemetry(
        unstartedPFrameCount: Int = 0,
        oldestUnstartedPFrameAgeMs: Double = 0,
        oldestUnstartedPFrameLatenessMs: Double = 0,
        packetPacerSleepMaxMs: Int = 0,
        packetPacerFrameMaxSleepMs: Int = 0,
        stalePacketDrops: UInt64 = 0,
        senderLocalDeadlineDrops: UInt64 = 0,
        lateNonKeyframeSends: UInt64 = 0,
        queuedUnreliableDeadlineExpiredDrops: UInt64 = 0,
        queuedUnreliableQueueLimitDrops: UInt64 = 0
    ) -> StreamPacketSender.TelemetrySnapshot {
        StreamPacketSender.TelemetrySnapshot(
            queuedBytes: 0,
            unstartedPFrameCount: unstartedPFrameCount,
            oldestUnstartedPFrameAgeMs: oldestUnstartedPFrameAgeMs,
            oldestUnstartedPFrameLatenessMs: oldestUnstartedPFrameLatenessMs,
            lateReservedPFrameStreak: 0,
            sendStartDelayAverageMs: 0,
            sendStartDelayMaxMs: 0,
            sendCompletionAverageMs: 0,
            sendCompletionMaxMs: 0,
            nonKeyframeSendStartDelayMaxMs: 0,
            nonKeyframeSendCompletionMaxMs: 0,
            packetPacerSleepAverageMs: 0,
            packetPacerSleepTotalMs: 0,
            packetPacerSleepMaxMs: packetPacerSleepMaxMs,
            packetPacerFrameMaxSleepMs: packetPacerFrameMaxSleepMs,
            stalePacketDrops: stalePacketDrops,
            senderLocalDeadlineDrops: senderLocalDeadlineDrops,
            lateNonKeyframeSends: lateNonKeyframeSends,
            generationAbortDrops: 0,
            nonKeyframeHoldDrops: 0,
            queuedUnreliableDeadlineExpiredDrops: queuedUnreliableDeadlineExpiredDrops,
            queuedUnreliableQueueLimitDrops: queuedUnreliableQueueLimitDrops,
            queuedUnreliableSupersededDrops: 0,
            queuedUnreliableUnsupportedTransportDrops: 0,
            queuedUnreliableClosedDrops: 0,
            queuedUnreliablePendingPackets: nil,
            queuedUnreliableOutstandingPackets: nil,
            queuedUnreliableQueuedBytes: nil,
            queuedUnreliablePendingPacketMax: nil,
            queuedUnreliableOutstandingPacketMax: nil,
            queuedUnreliableQueuedBytesMax: nil,
            queuedUnreliableEnqueuedCount: nil,
            queuedUnreliableSentCount: nil,
            queuedUnreliableCompletedCount: nil,
            queuedUnreliableDroppedCount: nil,
            queuedUnreliableErrorCount: nil,
            queuedUnreliableQueueDwellP50Ms: nil,
            queuedUnreliableQueueDwellP95Ms: nil,
            queuedUnreliableQueueDwellP99Ms: nil,
            queuedUnreliableSendGapP50Ms: nil,
            queuedUnreliableSendGapP95Ms: nil,
            queuedUnreliableSendGapP99Ms: nil,
            queuedUnreliableContentProcessedP50Ms: nil,
            queuedUnreliableContentProcessedP95Ms: nil,
            queuedUnreliableContentProcessedP99Ms: nil
        )
    }
}
#endif
