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

    private func makeSignal(
        pressureState: HostAdaptivePFrameController.PressureState = .observing,
        pressureReason: String? = nil,
        senderQueuedBytes: Int = 0,
        sourceStill: Bool = false,
        inputActive: Bool = true
    ) -> HostTransportFrameAdmissionPolicy.Signal {
        HostTransportFrameAdmissionPolicy.Signal(
            runtimeAdjustmentEnabled: true,
            currentFrameRate: 60,
            mediaPathProfile: .localWiFi,
            pressureState: pressureState,
            pressureReason: pressureReason,
            senderTelemetry: nil,
            queuePressureBytes: 1_200_000,
            maxQueuedBytes: max(2_000_000, senderQueuedBytes),
            receiverReassemblyBacklogFrames: 0,
            receiverReassemblyBacklogBytes: 0,
            receiverLossHoldActive: false,
            receiverAckLagMs: nil,
            receiverFeedbackAgeMs: 50,
            inputActive: inputActive,
            sourceStill: sourceStill
        )
    }
}
#endif
