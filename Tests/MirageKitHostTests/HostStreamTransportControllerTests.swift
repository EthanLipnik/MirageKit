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

        #expect(pressure?.pressureTrigger == .clientJitter)
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
