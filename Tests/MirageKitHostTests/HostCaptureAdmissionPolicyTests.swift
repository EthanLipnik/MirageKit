//
//  HostCaptureAdmissionPolicyTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 6/1/26.
//

#if os(macOS)
@testable import MirageKitHost
import MirageKit
import Testing

@Suite("Host Capture Admission Policy")
struct HostCaptureAdmissionPolicyTests {
    @Test("Freshest-frame lowest-latency admits new frames when inbox is full")
    func freshestFrameLowestLatencyAdmitsNewFramesWhenInboxIsFull() {
        let shouldDrop = HostCaptureAdmissionPolicy.shouldDropCapturedFrame(
            latencyMode: .lowestLatency,
            hostBufferingPolicy: .freshestFrame,
            pendingFrameCount: 1,
            frameCapacity: 1,
            backpressureActive: false
        )

        #expect(!shouldDrop)
    }

    @Test("Freshest-frame lowest-latency still drops under active backpressure")
    func freshestFrameLowestLatencyDropsUnderBackpressure() {
        let shouldDrop = HostCaptureAdmissionPolicy.shouldDropCapturedFrame(
            latencyMode: .lowestLatency,
            hostBufferingPolicy: .freshestFrame,
            pendingFrameCount: 1,
            frameCapacity: 1,
            backpressureActive: true
        )

        #expect(shouldDrop)
    }

    @Test("Stability buffering preserves full-inbox drop-new behavior")
    func stabilityBufferingDropsWhenInboxIsFull() {
        let shouldDrop = HostCaptureAdmissionPolicy.shouldDropCapturedFrame(
            latencyMode: .lowestLatency,
            hostBufferingPolicy: .stability,
            pendingFrameCount: 2,
            frameCapacity: 2,
            backpressureActive: false
        )

        #expect(shouldDrop)
    }

    @Test("Encoder lag admits newest replacement for balanced freshest-frame streams")
    func encoderLagAdmitsNewestReplacementForBalancedFreshestFrameStreams() {
        let shouldDrop = HostCaptureAdmissionPolicy.shouldDropCapturedFrame(
            latencyMode: .balanced,
            hostBufferingPolicy: .freshestFrame,
            pendingFrameCount: 2,
            frameCapacity: 2,
            backpressureActive: false,
            encoderLag: HostCaptureAdmissionPolicy.EncoderLagSnapshot(
                averageEncodeMs: 30,
                inFlightCount: 1,
                frameRate: 60
            )
        )

        #expect(!shouldDrop)
    }

    @Test("Balanced encoder lag drains newest when pending frames would go stale")
    func balancedEncoderLagDrainsNewestWhenPendingFramesWouldGoStale() {
        let shouldDrainNewest = HostCaptureAdmissionPolicy.shouldDrainNewestBeforeEncode(
            latencyMode: .balanced,
            hostBufferingPolicy: .freshestFrame,
            pendingFrameCount: 2,
            frameCapacity: 2,
            encoderLag: HostCaptureAdmissionPolicy.EncoderLagSnapshot(
                averageEncodeMs: 30,
                inFlightCount: 1,
                frameRate: 60
            )
        )

        #expect(shouldDrainNewest)
    }

    @Test("Smoothest encoder lag keeps a short elastic queue")
    func smoothestEncoderLagKeepsShortElasticQueue() {
        let shouldDrainNewest = HostCaptureAdmissionPolicy.shouldDrainNewestBeforeEncode(
            latencyMode: .smoothest,
            hostBufferingPolicy: .stability,
            pendingFrameCount: 2,
            frameCapacity: 3,
            encoderLag: HostCaptureAdmissionPolicy.EncoderLagSnapshot(
                averageEncodeMs: 30,
                inFlightCount: 1,
                frameRate: 60
            )
        )

        #expect(!shouldDrainNewest)
    }

    @Test("Smoothest encoder lag cuts before backlog can grow")
    func smoothestEncoderLagCutsBeforeBacklogCanGrow() {
        let shouldDropNewestCapture = HostCaptureAdmissionPolicy.shouldDropCapturedFrame(
            latencyMode: .smoothest,
            hostBufferingPolicy: .stability,
            pendingFrameCount: 3,
            frameCapacity: 3,
            backpressureActive: false,
            encoderLag: HostCaptureAdmissionPolicy.EncoderLagSnapshot(
                averageEncodeMs: 30,
                inFlightCount: 1,
                frameRate: 60
            )
        )
        let shouldDrainNewest = HostCaptureAdmissionPolicy.shouldDrainNewestBeforeEncode(
            latencyMode: .smoothest,
            hostBufferingPolicy: .stability,
            pendingFrameCount: 3,
            frameCapacity: 3,
            encoderLag: HostCaptureAdmissionPolicy.EncoderLagSnapshot(
                averageEncodeMs: 30,
                inFlightCount: 1,
                frameRate: 60
            )
        )

        #expect(!shouldDropNewestCapture)
        #expect(shouldDrainNewest)
        #expect(
            HostCaptureAdmissionPolicy.preEncodeBacklogCapMs(
                latencyMode: .smoothest,
                frameRate: 60
            ) <= 3_000
        )
    }
}
#endif
