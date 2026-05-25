//
//  HostStreamTransportControllerTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/14/26.
//

#if os(macOS)
@testable import MirageKit
@testable import MirageKitHost
import Testing

@Suite("Host Stream Transport Controller")
struct HostStreamTransportControllerTests {
    @Test("Receiver recovery feedback suppresses quality raises without changing frame admission")
    func receiverRecoveryFeedbackSuppressesQualityRaisesWithoutFrameAdmission() {
        var controller = HostStreamTransportController()

        let decision = controller.update(
            with: feedback(sequence: 1, recoveryState: .keyframeRecovery),
            currentFrameRate: 120,
            now: 10
        )

        #expect(decision?.frameAdmissionTargetFPS == nil)
        #expect(decision?.qualityRaiseSuppressionDeadline == 12)
        #expect(decision?.frameAdmissionTrigger == .clear)
    }

    @Test("Receiver backlog pressure enables temporary pre-encode frame admission")
    func receiverBacklogPressureEnablesTemporaryPreEncodeFrameAdmission() {
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

        #expect(pressure?.frameAdmissionTargetFPS == 90)
        #expect(pressure?.frameAdmissionDeadline == 22.5)
        #expect(pressure?.frameAdmissionTrigger == .clientReassemblyBacklog)

        let stale = controller.update(
            with: feedback(sequence: 2, targetFPS: 120, reassemblyBacklogFrames: 8),
            currentFrameRate: 120,
            now: 21
        )
        #expect(stale == nil)

        let cleared = controller.update(
            with: feedback(sequence: 3, targetFPS: 120),
            currentFrameRate: 120,
            now: 22.6
        )

        #expect(cleared?.frameAdmissionTargetFPS == nil)
        #expect(cleared?.frameAdmissionDeadline == 0)
        #expect(cleared?.frameAdmissionTrigger == .clear)
    }

    @Test("Sustained 120 Hz receiver pressure escalates admission relief to sixty")
    func sustainedOneTwentyReceiverPressureEscalatesAdmissionReliefToSixty() {
        var controller = HostStreamTransportController()

        _ = controller.update(
            with: feedback(sequence: 1, targetFPS: 120, reassemblyBacklogFrames: 8),
            currentFrameRate: 120,
            now: 20
        )
        let firstRelief = controller.update(
            with: feedback(sequence: 2, targetFPS: 120, reassemblyBacklogFrames: 8),
            currentFrameRate: 120,
            now: 20.5
        )
        _ = controller.update(
            with: feedback(sequence: 3, targetFPS: 120, reassemblyBacklogFrames: 8),
            currentFrameRate: 120,
            now: 21
        )
        let persistentRelief = controller.update(
            with: feedback(sequence: 4, targetFPS: 120, reassemblyBacklogFrames: 8),
            currentFrameRate: 120,
            now: 21.5
        )

        #expect(firstRelief?.frameAdmissionTargetFPS == 90)
        #expect(persistentRelief?.frameAdmissionTargetFPS == 60)
        #expect(persistentRelief?.frameAdmissionTrigger == .clientReassemblyBacklog)
    }

    @Test("Receiver jitter alone does not enable frame admission")
    func receiverJitterAloneDoesNotEnableFrameAdmission() {
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

    @Test("AWDL receiver jitter enables pacing without frame admission")
    func awdlReceiverJitterEnablesPacingWithoutFrameAdmission() {
        var controller = HostStreamTransportController()

        let firstSample = controller.update(
            with: feedback(sequence: 1, targetFPS: 60, jitterP99Ms: 90),
            currentFrameRate: 60,
            transportPathKind: .awdl,
            mediaPathProfile: .awdlRadio,
            now: 60
        )
        #expect(firstSample == nil)

        let pressure = controller.update(
            with: feedback(sequence: 2, targetFPS: 60, jitterP99Ms: 90),
            currentFrameRate: 60,
            transportPathKind: .awdl,
            mediaPathProfile: .awdlRadio,
            now: 60.5
        )

        #expect(pressure?.frameAdmissionTargetFPS == nil)
        #expect(pressure?.frameAdmissionDeadline == 0)
        #expect(pressure?.frameAdmissionTrigger == .clientJitter)
        #expect(pressure?.awdlPacingDeadline == 62.5)
        #expect(pressure?.awdlPacingTrigger == .clientJitter)
        #expect(pressure?.awdlPolicyState == .stressed)
        #expect(pressure?.awdlPolicyTrigger == .jitter)
        #expect(pressure?.awdlTargetFrameRate == 60)

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

    @Test("AWDL P-frame latency enables pacing and pre-encode admission relief")
    func awdlPFrameLatencyEnablesPacingAndAdmissionRelief() {
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

        #expect(pressure?.frameAdmissionTargetFPS == 30)
        #expect(pressure?.frameAdmissionTrigger == .clientPFrameLatency)
        #expect(pressure?.awdlPacingDeadline == 72.5)
        #expect(pressure?.awdlPacingTrigger == .clientPFrameLatency)
        #expect(pressure?.awdlPolicyState == .stressed)
        #expect(pressure?.awdlPolicyTrigger == .pFrameLatency)
    }

    @Test("Receiver transport loss requires sustained samples before admission")
    func receiverTransportLossRequiresSustainedSamplesBeforeAdmission() {
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
        #expect(pressure?.frameAdmissionTargetFPS == 30)
        #expect(pressure?.frameAdmissionTrigger == .clientTransportLoss)
    }

    @Test("Recovery and keyframe backlog suppress frame admission")
    func recoveryAndKeyframeBacklogSuppressFrameAdmission() {
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

        #expect(keyframeBacklog?.frameAdmissionTargetFPS == nil)
        #expect(keyframeBacklog?.frameAdmissionTrigger == .clear)
        #expect(keyframeBacklog?.qualityRaiseSuppressionDeadline == 53)
    }

    private func feedback(
        sequence: UInt64,
        targetFPS: Int = 60,
        lostFrameCount: UInt64 = 0,
        discardedPacketCount: UInt64 = 0,
        jitterP99Ms: Double = 0,
        reassemblyBacklogFrames: Int = 0,
        reassemblyBacklogKeyframes: Int = 0,
        reassemblyBacklogBytes: Int = 0,
        recoveryState: MirageMediaFeedbackRecoveryState = .idle,
        pFrameCompletionLatencyP95Ms: Double? = nil,
        latePFrameCount: UInt64? = nil
    ) -> ReceiverMediaFeedbackMessage {
        ReceiverMediaFeedbackMessage(
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
            latePFrameCount: latePFrameCount
        )
    }
}
#endif
