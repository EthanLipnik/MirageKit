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
    @Test("Controller ignores low receiver FPS without transport pressure")
    func ignoresReceiverFPSWithoutTransportPressure() {
        var controller = HostRealtimeAdaptationController()
        var action: HostRealtimeAdaptationAction = .hold

        for index in 0..<10 {
            action = controller.decide(
                input: feedbackInput(
                    currentBitrate: 100_000_000,
                    decodedFPS: 24,
                    rendererAcceptedFPS: 24,
                    rendererPresentedFPS: 24
                ),
                now: Double(index) * 0.5
            )
        }

        #expect(action == .hold)
        #expect(controller.sustainedBudgetFailureCount == 0)
    }

    @Test("Controller holds adaptation during recovery without transport pressure")
    func holdsDuringRecoveryWithoutTransportPressure() {
        var controller = HostRealtimeAdaptationController()
        var action: HostRealtimeAdaptationAction = .hold

        for index in 0..<10 {
            action = controller.decide(
                input: feedbackInput(
                    currentBitrate: 100_000_000,
                    recoveryState: .keyframeRecovery
                ),
                now: Double(index) * 0.5
            )
        }

        #expect(action == .hold)
        #expect(controller.sustainedBudgetFailureCount == 0)
    }

    @Test("Controller treats recovery packet discards as telemetry without transport pressure")
    func holdsDuringRecoveryDiscardTelemetryWithoutTransportPressure() {
        var controller = HostRealtimeAdaptationController()
        var action: HostRealtimeAdaptationAction = .hold

        for index in 0..<10 {
            action = controller.decide(
                input: feedbackInput(
                    currentBitrate: 100_000_000,
                    discardedPacketCount: UInt64(index + 1),
                    recoveryState: .keyframeRecovery
                ),
                now: Double(index) * 0.5
            )
        }

        #expect(action == .hold)
        #expect(controller.sustainedBudgetFailureCount == 0)
    }

    @Test("Controller ignores recovery jitter without transport pressure")
    func holdsDuringRecoveryJitterWithoutTransportPressure() {
        var controller = HostRealtimeAdaptationController()
        var action: HostRealtimeAdaptationAction = .hold

        for index in 0..<10 {
            action = controller.decide(
                input: feedbackInput(
                    currentBitrate: 100_000_000,
                    jitterP95Ms: 40,
                    jitterP99Ms: 50,
                    recoveryState: .keyframeRecovery
                ),
                now: Double(index) * 0.5
            )
        }

        #expect(action == .hold)
        #expect(controller.sustainedBudgetFailureCount == 0)
    }

    @Test("Controller does not act on stale pressure counters")
    func holdsWhenCurrentSampleHasNoTransportPressureAfterFailures() {
        var controller = HostRealtimeAdaptationController()

        for index in 0..<5 {
            _ = controller.decide(
                input: transportStressedInput(currentBitrate: 100_000_000),
                now: Double(index) * 0.5
            )
        }

        let action = controller.decide(
            input: feedbackInput(currentBitrate: 100_000_000),
            now: 2.5
        )

        #expect(action == .hold)
    }

    @Test("Controller reduces bitrate before quality or FPS")
    func reducesBitrateBeforeQualityOrFPS() {
        var controller = HostRealtimeAdaptationController()
        var action: HostRealtimeAdaptationAction = .hold

        for index in 0..<6 {
            action = controller.decide(
                input: transportStressedInput(currentBitrate: 100_000_000),
                now: Double(index) * 0.5
            )
        }

        #expect(action == .reduceBitrate(88_000_000, reason: "jitter"))
    }

    @Test("Controller reduces HEVC quality after bitrate floor under transport pressure")
    func reducesQualityAfterBitrateFloorUnderTransportPressure() {
        var controller = HostRealtimeAdaptationController()
        var action: HostRealtimeAdaptationAction = .hold

        for index in 0..<6 {
            action = controller.decide(
                input: transportStressedInput(currentBitrate: 25_000_000, activeQuality: 0.70, qualityFloor: 0.50),
                now: Double(index) * 0.5
            )
        }

        guard case let .reduceQuality(quality, reason) = action else {
            Issue.record("Expected quality reduction, got \(action)")
            return
        }
        #expect(abs(quality - 0.66) < 0.001)
        #expect(reason == "jitter")
    }

    @Test("Controller only reduces FPS after sustained lower-tier failures")
    func reducesFPSAfterSustainedLowerTierFailures() {
        var controller = HostRealtimeAdaptationController()
        var action: HostRealtimeAdaptationAction = .hold

        for index in 0..<31 {
            let nextAction = controller.decide(
                input: transportStressedInput(
                    currentBitrate: 25_000_000,
                    activeQuality: 0.50,
                    qualityFloor: 0.50,
                    colorDepth: .standard,
                    streamScale: 0.70,
                    currentFrameRate: 120
                ),
                now: Double(index) * 0.5
            )
            if nextAction != .hold {
                action = nextAction
            }
        }

        #expect(action == .reduceFrameRate(60, reason: "jitter"))
    }

    @Test("Controller holds when app owns automatic bitrate adaptation")
    func holdsWhenAppOwnsAutomaticBitrateAdaptation() {
        var controller = HostRealtimeAdaptationController()
        var action: HostRealtimeAdaptationAction = .hold

        for index in 0..<10 {
            action = controller.decide(
                input: transportStressedInput(
                    currentBitrate: 100_000_000,
                    appOwnedBitrateAdaptation: true
                ),
                now: Double(index) * 0.5
            )
        }

        #expect(action == .hold)
        #expect(controller.sustainedBudgetFailureCount == 0)
        #expect(controller.feedbackSampleCount == 0)
    }

    private func transportStressedInput(
        currentBitrate: Int?,
        activeQuality: Float = 0.80,
        qualityFloor: Float = 0.50,
        colorDepth: MirageStreamColorDepth = .standard,
        streamScale: Double = 1.0,
        currentFrameRate: Int = 120,
        appOwnedBitrateAdaptation: Bool = false
    ) -> HostRealtimeAdaptationInput {
        feedbackInput(
            currentBitrate: currentBitrate,
            activeQuality: activeQuality,
            qualityFloor: qualityFloor,
            colorDepth: colorDepth,
            streamScale: streamScale,
            currentFrameRate: currentFrameRate,
            jitterP95Ms: 40,
            jitterP99Ms: 50,
            appOwnedBitrateAdaptation: appOwnedBitrateAdaptation
        )
    }

    private func feedbackInput(
        currentBitrate: Int?,
        activeQuality: Float = 0.80,
        qualityFloor: Float = 0.50,
        colorDepth: MirageStreamColorDepth = .standard,
        streamScale: Double = 1.0,
        currentFrameRate: Int = 120,
        lostFrameCount: UInt64 = 0,
        discardedPacketCount: UInt64 = 0,
        jitterP95Ms: Double = 2,
        jitterP99Ms: Double = 3,
        queueEstimateFrames: Int = 0,
        reassemblyBacklogFrames: Int = 0,
        reassemblyBacklogBytes: Int = 0,
        decodedFPS: Double = 118,
        rendererAcceptedFPS: Double = 118,
        rendererPresentedFPS: Double = 118,
        recoveryState: MirageMediaFeedbackRecoveryState = .idle,
        appOwnedBitrateAdaptation: Bool = false
    ) -> HostRealtimeAdaptationInput {
        HostRealtimeAdaptationInput(
            feedback: ReceiverMediaFeedbackMessage(
                streamID: 1,
                sequence: 1,
                sentAtUptime: 1,
                targetFPS: currentFrameRate,
                ackRanges: [],
                lostFrameCount: lostFrameCount,
                discardedPacketCount: discardedPacketCount,
                jitterP95Ms: jitterP95Ms,
                jitterP99Ms: jitterP99Ms,
                queueEstimateFrames: queueEstimateFrames,
                reassemblyBacklogFrames: reassemblyBacklogFrames,
                reassemblyBacklogKeyframes: 0,
                reassemblyBacklogBytes: reassemblyBacklogBytes,
                decodeBacklogFrames: 0,
                presentationBacklogFrames: 0,
                decodedFPS: decodedFPS,
                receivedFPS: 118,
                rendererAcceptedFPS: rendererAcceptedFPS,
                rendererPresentedFPS: rendererPresentedFPS,
                recoveryState: recoveryState
            ),
            currentBitrate: currentBitrate,
            activeQuality: activeQuality,
            qualityFloor: qualityFloor,
            colorDepth: colorDepth,
            streamScale: streamScale,
            currentFrameRate: currentFrameRate,
            appOwnedBitrateAdaptation: appOwnedBitrateAdaptation
        )
    }
}
#endif
