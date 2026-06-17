//
//  HostTransportFrameAdmissionPolicyTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 6/12/26.
//

#if os(macOS)
@testable import MirageKitHost
import MirageKit
import Testing

@Suite("Host Transport Frame Admission Policy")
struct HostTransportFrameAdmissionPolicyTests {
    @Test("Transport pressure admits then skips until the soft interval elapses")
    func transportPressureAdmitsThenSkipsUntilSoftIntervalElapses() {
        var state = HostTransportFrameAdmissionPolicy.State()
        let signal = makeSignal(
            pressureState: .pressured,
            pressureReason: HostAdaptivePFrameController.Reason.transportBacklog.rawValue
        )

        let first = HostTransportFrameAdmissionPolicy.evaluate(
            state: &state,
            signal: signal,
            bypass: false,
            now: 100
        )
        let second = HostTransportFrameAdmissionPolicy.evaluate(
            state: &state,
            signal: signal,
            bypass: false,
            now: 100.010
        )
        let third = HostTransportFrameAdmissionPolicy.evaluate(
            state: &state,
            signal: signal,
            bypass: false,
            now: 100.034
        )

        #expect(first.admitsFrame)
        #expect(first.mode == .softThrottle)
        #expect(!second.admitsFrame)
        #expect(second.minimumFrameIntervalMs > 30)
        #expect(third.admitsFrame)
    }

    @Test("Forced frames bypass hard transport throttling")
    func forcedFramesBypassHardTransportThrottling() {
        var state = HostTransportFrameAdmissionPolicy.State()
        let signal = makeSignal(
            pressureState: .severe,
            pressureReason: HostAdaptivePFrameController.Reason.transportBacklog.rawValue,
            senderQueuedBytes: 2_000_000
        )

        let first = HostTransportFrameAdmissionPolicy.evaluate(
            state: &state,
            signal: signal,
            bypass: false,
            now: 200
        )
        let bypassed = HostTransportFrameAdmissionPolicy.evaluate(
            state: &state,
            signal: signal,
            bypass: true,
            now: 200.005
        )

        #expect(first.admitsFrame)
        #expect(first.mode == .hardThrottle)
        #expect(first.reason == HostAdaptivePFrameController.Reason.transportBacklog.rawValue)
        #expect(first.evidence == "hard:transport-backlog")
        #expect(first.activeHoldMs > 0)
        #expect(bypassed.admitsFrame)
        #expect(bypassed.mode == .hardThrottle)
    }

    @Test("Still clean source releases stale transport throttling immediately")
    func stillCleanSourceReleasesStaleTransportThrottlingImmediately() {
        var state = HostTransportFrameAdmissionPolicy.State(
            mode: .hardThrottle,
            activeUntil: 301,
            lastAdmittedFrameTime: 300,
            lastLoggedMode: .hardThrottle,
            lastSkipLogTime: 0
        )
        let signal = makeSignal(
            pressureState: .observing,
            pressureReason: nil,
            sourceStill: true,
            inputActive: false
        )

        let decision = HostTransportFrameAdmissionPolicy.evaluate(
            state: &state,
            signal: signal,
            bypass: false,
            now: 300.010
        )

        #expect(decision.admitsFrame)
        #expect(decision.mode == .normal)
        #expect(state.mode == .normal)
        #expect(state.activeUntil == 0)
    }

    @Test("Non-transport pressure reason does not activate admission throttling")
    func nonTransportPressureReasonDoesNotActivateAdmissionThrottling() {
        var state = HostTransportFrameAdmissionPolicy.State()
        let signal = makeSignal(
            pressureState: .pressured,
            pressureReason: HostAdaptivePFrameController.Reason.encoderLag.rawValue
        )

        let decision = HostTransportFrameAdmissionPolicy.evaluate(
            state: &state,
            signal: signal,
            bypass: false,
            now: 400
        )

        #expect(decision.admitsFrame)
        #expect(decision.mode == .normal)
    }

    @Test("Non-actionable transport pressure reason does not activate admission throttling")
    func nonActionableTransportPressureReasonDoesNotActivateAdmissionThrottling() {
        var state = HostTransportFrameAdmissionPolicy.State()
        let signal = makeSignal(
            pressureState: .pressured,
            pressureReason: HostAdaptivePFrameController.Reason.transportBacklog.rawValue,
            transportPressureIsActionable: false
        )

        let decision = HostTransportFrameAdmissionPolicy.evaluate(
            state: &state,
            signal: signal,
            bypass: false,
            now: 450
        )

        #expect(decision.admitsFrame)
        #expect(decision.mode == .normal)
    }

    @Test("Historical queued-unreliable burst maxima do not activate admission throttling")
    func historicalQueuedUnreliableBurstMaximaDoNotActivateAdmissionThrottling() {
        var state = HostTransportFrameAdmissionPolicy.State()
        let signal = makeSignal(
            senderTelemetry: makeSenderTelemetry(
                queuedUnreliablePendingPacketMax: 64,
                queuedUnreliableOutstandingPacketMax: 64,
                queuedUnreliableQueuedBytesMax: 160 * 1024
            )
        )

        let decision = HostTransportFrameAdmissionPolicy.evaluate(
            state: &state,
            signal: signal,
            bypass: false,
            now: 460
        )

        #expect(decision.admitsFrame)
        #expect(decision.mode == .normal)
    }

    @Test("Clean live queued-unreliable backlog does not activate admission throttling")
    func cleanLiveQueuedUnreliableBacklogDoesNotActivateAdmissionThrottling() {
        var state = HostTransportFrameAdmissionPolicy.State()
        let signal = makeSignal(
            senderTelemetry: makeSenderTelemetry(
                queuedUnreliablePendingPackets: 10,
                queuedUnreliableQueuedBytes: 96 * 1024
            )
        )

        let decision = HostTransportFrameAdmissionPolicy.evaluate(
            state: &state,
            signal: signal,
            bypass: false,
            now: 470
        )

        #expect(decision.admitsFrame)
        #expect(decision.mode == .normal)
    }

    @Test("Live queued-unreliable backlog with timing pressure activates admission throttling")
    func liveQueuedUnreliableBacklogWithTimingPressureActivatesAdmissionThrottling() {
        var state = HostTransportFrameAdmissionPolicy.State()
        let signal = makeSignal(
            mediaPathProfile: .vpnOrOverlay,
            senderTelemetry: makeSenderTelemetry(
                queuedUnreliablePendingPackets: 10,
                queuedUnreliableQueuedBytes: 96 * 1024,
                queuedUnreliableQueueDwellP99Ms: 180
            )
        )

        let decision = HostTransportFrameAdmissionPolicy.evaluate(
            state: &state,
            signal: signal,
            bypass: false,
            now: 470
        )

        #expect(decision.mode == .softThrottle)
        #expect(decision.evidence == "soft:transport-backlog")
    }

    @Test("Local bulk late sends do not activate admission throttling")
    func localBulkLateSendsDoNotActivateAdmissionThrottling() {
        var state = HostTransportFrameAdmissionPolicy.State()
        _ = HostTransportFrameAdmissionPolicy.evaluate(
            state: &state,
            signal: makeSignal(mediaPathProfile: .proximityWiredLike),
            bypass: false,
            now: 475
        )
        let signal = makeSignal(
            mediaPathProfile: .proximityWiredLike,
            senderTelemetry: makeSenderTelemetry(lateNonKeyframeSends: 2)
        )

        let decision = HostTransportFrameAdmissionPolicy.evaluate(
            state: &state,
            signal: signal,
            bypass: false,
            now: 476
        )

        #expect(decision.admitsFrame)
        #expect(decision.mode == .normal)
    }

    @Test("Local bulk queue limit drops still activate hard admission throttling")
    func localBulkQueueLimitDropsStillActivateHardAdmissionThrottling() {
        var state = HostTransportFrameAdmissionPolicy.State()
        _ = HostTransportFrameAdmissionPolicy.evaluate(
            state: &state,
            signal: makeSignal(mediaPathProfile: .proximityWiredLike),
            bypass: false,
            now: 477
        )
        let signal = makeSignal(
            mediaPathProfile: .proximityWiredLike,
            senderTelemetry: makeSenderTelemetry(queuedUnreliableQueueLimitDrops: 1)
        )

        let decision = HostTransportFrameAdmissionPolicy.evaluate(
            state: &state,
            signal: signal,
            bypass: false,
            now: 478
        )

        #expect(decision.mode == .hardThrottle)
        #expect(decision.evidence == "hard:transport-backlog")
    }

    @Test("Non-actionable receiver ack lag does not activate admission throttling")
    func nonActionableReceiverAckLagDoesNotActivateAdmissionThrottling() {
        var state = HostTransportFrameAdmissionPolicy.State()
        let signal = makeSignal(
            pressureState: .severe,
            pressureReason: HostAdaptivePFrameController.Reason.pFrameLatency.rawValue,
            transportPressureIsActionable: false,
            receiverAckLagMs: 900
        )

        let decision = HostTransportFrameAdmissionPolicy.evaluate(
            state: &state,
            signal: signal,
            bypass: false,
            now: 480
        )

        #expect(decision.admitsFrame)
        #expect(decision.mode == .normal)
    }

    @Test("Repeated sender drop telemetry does not refresh transport admission hold")
    func repeatedSenderDropTelemetryDoesNotRefreshTransportAdmissionHold() {
        var state = HostTransportFrameAdmissionPolicy.State()
        _ = HostTransportFrameAdmissionPolicy.evaluate(
            state: &state,
            signal: makeSignal(),
            bypass: false,
            now: 499
        )
        let signal = makeSignal(
            senderTelemetry: makeSenderTelemetry(senderLocalDeadlineDrops: 1)
        )

        let first = HostTransportFrameAdmissionPolicy.evaluate(
            state: &state,
            signal: signal,
            bypass: false,
            now: 500
        )
        let repeated = HostTransportFrameAdmissionPolicy.evaluate(
            state: &state,
            signal: signal,
            bypass: false,
            now: 500.200
        )
        let released = HostTransportFrameAdmissionPolicy.evaluate(
            state: &state,
            signal: signal,
            bypass: false,
            now: 500.500
        )

        #expect(first.mode == .softThrottle)
        #expect(repeated.mode == .softThrottle)
        #expect(repeated.evidence == nil)
        #expect(released.mode == .normal)
        #expect(released.admitsFrame)
    }

    @Test("Incremented sender drop telemetry activates transport admission pressure")
    func incrementedSenderDropTelemetryActivatesTransportAdmissionPressure() {
        var state = HostTransportFrameAdmissionPolicy.State()
        _ = HostTransportFrameAdmissionPolicy.evaluate(
            state: &state,
            signal: makeSignal(),
            bypass: false,
            now: 599
        )
        let clean = makeSignal(
            senderTelemetry: makeSenderTelemetry(senderLocalDeadlineDrops: 1)
        )
        let incremented = makeSignal(
            senderTelemetry: makeSenderTelemetry(senderLocalDeadlineDrops: 2)
        )

        _ = HostTransportFrameAdmissionPolicy.evaluate(
            state: &state,
            signal: clean,
            bypass: false,
            now: 600
        )
        let decision = HostTransportFrameAdmissionPolicy.evaluate(
            state: &state,
            signal: incremented,
            bypass: false,
            now: 601
        )

        #expect(decision.mode == .softThrottle)
        #expect(decision.evidence == "soft:transport-backlog")
    }

    @Test("Repeated queue limit telemetry does not keep hard transport admission active")
    func repeatedQueueLimitTelemetryDoesNotKeepHardTransportAdmissionActive() {
        var state = HostTransportFrameAdmissionPolicy.State()
        _ = HostTransportFrameAdmissionPolicy.evaluate(
            state: &state,
            signal: makeSignal(),
            bypass: false,
            now: 699
        )
        let signal = makeSignal(
            senderTelemetry: makeSenderTelemetry(queuedUnreliableQueueLimitDrops: 1)
        )

        let first = HostTransportFrameAdmissionPolicy.evaluate(
            state: &state,
            signal: signal,
            bypass: false,
            now: 700
        )
        let repeated = HostTransportFrameAdmissionPolicy.evaluate(
            state: &state,
            signal: signal,
            bypass: false,
            now: 700.400
        )
        let released = HostTransportFrameAdmissionPolicy.evaluate(
            state: &state,
            signal: signal,
            bypass: false,
            now: 700.900
        )

        #expect(first.mode == .hardThrottle)
        #expect(repeated.mode == .hardThrottle)
        #expect(repeated.evidence == nil)
        #expect(released.mode == .normal)
        #expect(released.admitsFrame)
    }

    private func makeSignal(
        mediaPathProfile: MirageMediaPathProfile = .localWiFi,
        pressureState: HostAdaptivePFrameController.PressureState = .observing,
        pressureReason: String? = nil,
        transportPressureIsActionable: Bool = true,
        senderQueuedBytes: Int = 0,
        senderTelemetry: StreamPacketSender.TelemetrySnapshot? = nil,
        sourceStill: Bool = false,
        inputActive: Bool = true,
        receiverAckLagMs: Double? = nil
    ) -> HostTransportFrameAdmissionPolicy.Signal {
        HostTransportFrameAdmissionPolicy.Signal(
            runtimeAdjustmentEnabled: true,
            currentFrameRate: 60,
            mediaPathProfile: mediaPathProfile,
            pressureState: pressureState,
            pressureReason: pressureReason,
            transportPressureIsActionable: transportPressureIsActionable,
            senderTelemetry: senderTelemetry,
            queuePressureBytes: 1_200_000,
            maxQueuedBytes: max(2_000_000, senderQueuedBytes),
            receiverReassemblyBacklogFrames: 0,
            receiverReassemblyBacklogBytes: 0,
            receiverLossHoldActive: false,
            receiverAckLagMs: receiverAckLagMs,
            receiverFeedbackAgeMs: 50,
            inputActive: inputActive,
            sourceStill: sourceStill
        )
    }

    private func makeSenderTelemetry(
        senderLocalDeadlineDrops: UInt64 = 0,
        stalePacketDrops: UInt64 = 0,
        lateNonKeyframeSends: UInt64 = 0,
        queuedUnreliableDeadlineExpiredDrops: UInt64 = 0,
        queuedUnreliableQueueLimitDrops: UInt64 = 0,
        queuedUnreliablePendingPackets: Int? = nil,
        queuedUnreliableOutstandingPackets: Int? = nil,
        queuedUnreliableQueuedBytes: Int? = nil,
        queuedUnreliableQueueDwellP99Ms: Double? = nil,
        queuedUnreliablePendingPacketMax: Int? = nil,
        queuedUnreliableOutstandingPacketMax: Int? = nil,
        queuedUnreliableQueuedBytesMax: Int? = nil
    ) -> StreamPacketSender.TelemetrySnapshot {
        StreamPacketSender.TelemetrySnapshot(
            queuedBytes: 0,
            unstartedPFrameCount: 0,
            oldestUnstartedPFrameAgeMs: 0,
            oldestUnstartedPFrameLatenessMs: 0,
            lateReservedPFrameStreak: 0,
            sendStartDelayAverageMs: 0,
            sendStartDelayMaxMs: 0,
            sendCompletionAverageMs: 0,
            sendCompletionMaxMs: 0,
            nonKeyframeSendStartDelayMaxMs: 0,
            nonKeyframeSendCompletionMaxMs: 0,
            packetPacerSleepAverageMs: 0,
            packetPacerSleepTotalMs: 0,
            packetPacerSleepMaxMs: 0,
            packetPacerFrameMaxSleepMs: 0,
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
            queuedUnreliablePendingPackets: queuedUnreliablePendingPackets,
            queuedUnreliableOutstandingPackets: queuedUnreliableOutstandingPackets,
            queuedUnreliableQueuedBytes: queuedUnreliableQueuedBytes,
            queuedUnreliablePendingPacketMax: queuedUnreliablePendingPacketMax,
            queuedUnreliableOutstandingPacketMax: queuedUnreliableOutstandingPacketMax,
            queuedUnreliableQueuedBytesMax: queuedUnreliableQueuedBytesMax,
            queuedUnreliableEnqueuedCount: nil,
            queuedUnreliableSentCount: nil,
            queuedUnreliableCompletedCount: nil,
            queuedUnreliableDroppedCount: nil,
            queuedUnreliableErrorCount: nil,
            queuedUnreliableQueueDwellP50Ms: nil,
            queuedUnreliableQueueDwellP95Ms: nil,
            queuedUnreliableQueueDwellP99Ms: queuedUnreliableQueueDwellP99Ms,
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
