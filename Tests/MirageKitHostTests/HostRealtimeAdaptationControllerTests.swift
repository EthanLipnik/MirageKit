//
//  HostRealtimeAdaptationControllerTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/5/26.
//

@testable import MirageKit
@testable import MirageKitHost
import Foundation
import Testing

#if os(macOS)
@Suite("Host Realtime Adaptation Controller")
struct HostRealtimeAdaptationControllerTests {
    @Test("Controller reduces bitrate before quality or FPS")
    func reducesBitrateBeforeQualityOrFPS() {
        var controller = HostRealtimeAdaptationController()
        var action: HostRealtimeAdaptationAction = .hold

        for index in 0..<3 {
            action = controller.decide(
                input: stressedInput(currentBitrate: 100_000_000),
                now: Double(index) * 0.4
            )
        }

        #expect(action == .reduceBitrate(88_000_000, reason: "receiver-fps+backlog+jitter+recovery"))
    }

    @Test("Controller reduces quality after bitrate floor")
    func reducesQualityAfterBitrateFloor() {
        var controller = HostRealtimeAdaptationController()
        var action: HostRealtimeAdaptationAction = .hold

        for index in 0..<6 {
            action = controller.decide(
                input: stressedInput(currentBitrate: 25_000_000, activeQuality: 0.70, qualityFloor: 0.50),
                now: Double(index) * 0.4
            )
        }

        guard case let .reduceQuality(quality, reason) = action else {
            Issue.record("Expected quality reduction, got \(action)")
            return
        }
        #expect(abs(quality - 0.66) < 0.001)
        #expect(reason == "receiver-fps+backlog+jitter+recovery")
    }

    @Test("Controller only reduces FPS after sustained lower-tier failures")
    func reducesFPSAfterSustainedLowerTierFailures() {
        var controller = HostRealtimeAdaptationController()
        var action: HostRealtimeAdaptationAction = .hold

        for index in 0..<31 {
            let nextAction = controller.decide(
                input: stressedInput(
                    currentBitrate: 25_000_000,
                    activeQuality: 0.50,
                    qualityFloor: 0.50,
                    colorDepth: .standard,
                    streamScale: 0.70,
                    currentFrameRate: 120
                ),
                now: Double(index) * 0.4
            )
            if nextAction != .hold {
                action = nextAction
            }
        }

        #expect(action == .reduceFrameRate(60, reason: "receiver-fps+backlog+jitter+recovery"))
    }

    private func stressedInput(
        currentBitrate: Int?,
        activeQuality: Float = 0.80,
        qualityFloor: Float = 0.50,
        colorDepth: MirageStreamColorDepth = .standard,
        streamScale: Double = 1.0,
        currentFrameRate: Int = 120
    ) -> HostRealtimeAdaptationInput {
        HostRealtimeAdaptationInput(
            feedback: ReceiverMediaFeedbackMessage(
                streamID: 1,
                sequence: 1,
                sentAtUptime: 1,
                targetFPS: currentFrameRate,
                ackRanges: [],
                lostFrameCount: 0,
                discardedPacketCount: 0,
                jitterP95Ms: 40,
                jitterP99Ms: 50,
                queueEstimateFrames: 8,
                reassemblyBacklogFrames: 2,
                reassemblyBacklogKeyframes: 1,
                reassemblyBacklogBytes: 4096,
                decodeBacklogFrames: 3,
                presentationBacklogFrames: 3,
                decodedFPS: 70,
                receivedFPS: 118,
                rendererAcceptedFPS: 72,
                rendererPresentedFPS: 70,
                recoveryState: .keyframeRecovery
            ),
            currentBitrate: currentBitrate,
            activeQuality: activeQuality,
            qualityFloor: qualityFloor,
            colorDepth: colorDepth,
            streamScale: streamScale,
            currentFrameRate: currentFrameRate
        )
    }
}
#endif
