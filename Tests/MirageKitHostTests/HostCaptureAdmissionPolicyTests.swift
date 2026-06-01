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
}
#endif
