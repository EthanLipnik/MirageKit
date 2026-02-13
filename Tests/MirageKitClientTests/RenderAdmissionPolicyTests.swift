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
    @Test("Cap for 60Hz with two drawables")
    func capFor60HzWithTwoDrawables() {
        let cap = MirageRenderAdmissionPolicy.effectiveInFlightCap(targetFPS: 60, maximumDrawableCount: 2)
        #expect(cap == 2)
    }

    @Test("Cap for 120Hz with two drawables")
    func capFor120HzWithTwoDrawables() {
        let cap = MirageRenderAdmissionPolicy.effectiveInFlightCap(targetFPS: 120, maximumDrawableCount: 2)
        #expect(cap == 2)
    }

    @Test("Cap for 120Hz with three drawables")
    func capFor120HzWithThreeDrawables() {
        let cap = MirageRenderAdmissionPolicy.effectiveInFlightCap(targetFPS: 120, maximumDrawableCount: 3)
        #expect(cap == 3)
    }

    @Test("Cap for one drawable")
    func capForOneDrawable() {
        let cap = MirageRenderAdmissionPolicy.effectiveInFlightCap(targetFPS: 60, maximumDrawableCount: 1)
        #expect(cap == 1)
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
