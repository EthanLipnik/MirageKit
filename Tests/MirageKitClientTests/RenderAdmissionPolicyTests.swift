//
//  RenderAdmissionPolicyTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/12/26.
//
//  Coverage for render admission policy and in-flight accounting.
//

@testable import MirageKitClient
import Testing

#if os(macOS)
@Suite("Render Admission Policy")
struct RenderAdmissionPolicyTests {
    @Test("Legacy cap API clamps to drawable count")
    func legacyCapClampsToDrawableCount() {
        let cap = MirageRenderAdmissionPolicy.effectiveInFlightCap(targetFPS: 60, maximumDrawableCount: 2)
        #expect(cap == 2)
    }

    @Test("Lowest latency at 60Hz keeps one in-flight")
    func lowestLatency60HzPolicy() {
        let decision = MirageRenderAdmissionPolicy.decision(
            latencyMode: .lowestLatency,
            targetFPS: 60,
            typingBurstActive: false,
            recoveryActive: false,
            smoothestPromotionActive: false
        )
        #expect(decision.inFlightCap == 1)
        #expect(decision.maximumDrawableCount == 2)
        #expect(decision.reason == .baseline)
        #expect(!decision.allowsSecondaryCatchUpDraw)
    }

    @Test("Auto baseline at 60Hz keeps two in-flight")
    func auto60HzBaselinePolicy() {
        let decision = MirageRenderAdmissionPolicy.decision(
            latencyMode: .auto,
            targetFPS: 60,
            typingBurstActive: false,
            recoveryActive: false,
            smoothestPromotionActive: false
        )
        #expect(decision.inFlightCap == 2)
        #expect(decision.maximumDrawableCount == 2)
        #expect(decision.reason == .baseline)
    }

    @Test("Auto typing burst at 60Hz drops to one in-flight")
    func autoTypingPolicy() {
        let decision = MirageRenderAdmissionPolicy.decision(
            latencyMode: .auto,
            targetFPS: 60,
            typingBurstActive: true,
            recoveryActive: false,
            smoothestPromotionActive: false
        )
        #expect(decision.inFlightCap == 1)
        #expect(decision.maximumDrawableCount == 2)
        #expect(decision.reason == .typing)
    }

    @Test("Recovery forces one in-flight for all modes")
    func recoveryForcesSingleInFlight() {
        let decision = MirageRenderAdmissionPolicy.decision(
            latencyMode: .smoothest,
            targetFPS: 60,
            typingBurstActive: false,
            recoveryActive: true,
            smoothestPromotionActive: true
        )
        #expect(decision.inFlightCap == 1)
        #expect(decision.maximumDrawableCount == 3)
        #expect(decision.reason == .recovery)
    }

    @Test("Smoothest promotion enables three drawables and three in-flight")
    func smoothestPromotionPolicy() {
        let decision = MirageRenderAdmissionPolicy.decision(
            latencyMode: .smoothest,
            targetFPS: 60,
            typingBurstActive: false,
            recoveryActive: false,
            smoothestPromotionActive: true
        )
        #expect(decision.inFlightCap == 3)
        #expect(decision.maximumDrawableCount == 3)
        #expect(decision.reason == .promotion)
        #expect(decision.allowsSecondaryCatchUpDraw)
    }

    @Test("120Hz baseline keeps three in-flight")
    func baseline120HzPolicy() {
        let decision = MirageRenderAdmissionPolicy.decision(
            latencyMode: .auto,
            targetFPS: 120,
            typingBurstActive: false,
            recoveryActive: false,
            smoothestPromotionActive: false
        )
        #expect(decision.inFlightCap == 3)
        #expect(decision.maximumDrawableCount == 3)
        #expect(decision.reason == .baseline)
        #expect(decision.allowsSecondaryCatchUpDraw)
    }

    @Test("In-flight counter acquires and releases once")
    func inFlightCounterAcquireRelease() {
        let counter = MirageRenderAdmissionCounter()

        #expect(counter.tryAcquire(limit: 2))
        #expect(counter.tryAcquire(limit: 2))
        #expect(!counter.tryAcquire(limit: 2))
        #expect(counter.snapshot() == 2)

        #expect(counter.release())
        #expect(counter.snapshot() == 1)
        #expect(counter.release())
        #expect(counter.snapshot() == 0)

        #expect(!counter.release())
        #expect(counter.snapshot() == 0)
    }

    @Test("Sequence gate allows requested frame until newer frame is presented")
    func sequenceGateUsesPresentedOrdering() {
        let gate = MirageRenderSequenceGate()
        gate.noteRequested(10)
        gate.noteRequested(11)

        #expect(!gate.isStale(10))
        #expect(!gate.isStale(11))

        gate.notePresented(11)

        #expect(gate.isStale(10))
        #expect(gate.isStale(11))
        #expect(!gate.isStale(12))
    }

    @Test("Sequence gate resets when sequence numbering restarts")
    func sequenceGateRecoversFromSequenceRestart() {
        let gate = MirageRenderSequenceGate()
        gate.noteRequested(5_000)
        gate.notePresented(5_000)
        #expect(gate.isStale(10))

        gate.noteRequested(1)

        #expect(!gate.isStale(1))
        #expect(!gate.isStale(2))
    }
}
#endif
