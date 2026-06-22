//
//  AppStreamRecoveryParityTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/5/26.
//

#if os(macOS)
@testable import MirageKitHost
import CoreGraphics
import Foundation
import MirageKit
import Testing

@Suite("App Stream Recovery Parity")
struct AppStreamRecoveryParityTests {
    @Test("Window streaming preparation restores minimized windows and exits full screen")
    func windowStreamingPreparationRestoresMinimizedWindowsAndExitsFullScreen() {
        let plan = MirageHostService.windowStreamingPreparationPlan(
            isOnScreen: false,
            isFullScreen: true
        )

        #expect(plan.shouldRestoreWindow)
        #expect(plan.shouldExitFullScreen)
        #expect(plan.settleDelayMilliseconds == 350)
    }

    @MainActor
    @Test("Dedicated app virtual-display streams honor encoder-settings scale updates")
    func dedicatedAppVirtualDisplayStreamsHonorEncoderSettingsScaleUpdates() async {
        let host = MirageHostService(hostName: "AppStreamScaleHost")
        let context = makeContext(streamID: 77)
        await context.configureForDedicatedVirtualDisplayTest(
            baseCaptureSize: CGSize(width: 3_200, height: 2_080),
            windowFrame: CGRect(x: 0, y: 0, width: 1_600, height: 1_040),
            displaySnapshot: makeDisplaySnapshot(),
            visibleBounds: CGRect(x: 0, y: 0, width: 1_600, height: 1_040)
        )
        host.streamsByID[77] = context

        await host.handleStreamEncoderSettingsChange(
            StreamEncoderSettingsChangeMessage(
                streamID: 77,
                streamScale: 0.8
            )
        )

        #expect(abs((await context.streamScale) - 0.8) < 0.001)
        #expect(await context.streamStartSnapshot.dimensionToken == 1)

        let encodedDimensions = await context.encodedDimensions
        #expect(encodedDimensions.width == 2_560)
        #expect(encodedDimensions.height == 1_664)
    }

    @MainActor
    @Test("AWDL interactive feedback keeps fixed cadence and resolution")
    func awdlInteractiveFeedbackKeepsFixedCadenceAndResolution() async {
        let context = makeContext(streamID: 82, mediaPathProfile: .awdlRadio)
        await context.configureForDedicatedVirtualDisplayTest(
            baseCaptureSize: CGSize(width: 2_752, height: 2_064),
            windowFrame: CGRect(x: 0, y: 0, width: 1_376, height: 1_032),
            displaySnapshot: makeDisplaySnapshot(),
            visibleBounds: CGRect(x: 0, y: 0, width: 1_376, height: 1_032)
        )
        let initialToken = await context.streamStartSnapshot.dimensionToken
        let geometryRecorder = AwdlGeometryUpdateRecorder()
        let cadenceRecorder = AwdlGeometryUpdateRecorder()
        await context.setHostAdaptiveDesktopGeometryUpdateHandler { streamID in
            geometryRecorder.record(streamID)
        }
        await context.setHostAdaptiveDesktopCadenceUpdateHandler { streamID in
            cadenceRecorder.record(streamID)
        }

        await applyAwdlPressureFeedback(context)

        #expect(geometryRecorder.streamIDs.isEmpty)
        #expect(cadenceRecorder.streamIDs.isEmpty)
        #expect(context.currentFrameRate == MirageAwdlMediaController.awdlRadioFrameRate)
        #expect(await context.streamStartSnapshot.targetFrameRate == MirageAwdlMediaController.awdlRadioFrameRate)
        #expect(await context.streamStartSnapshot.dimensionToken == initialToken)
        #expect(abs((await context.streamScale) - 1.0) < 0.001)
    }

    @MainActor
    @Test("AWDL emergency keyframes honor interactive quality floor")
    func awdlEmergencyKeyframesHonorInteractiveQualityFloor() async {
        let context = makeContext(streamID: 79, mediaPathProfile: .awdlRadio)
        await context.configureEmergencyKeyframeActiveQuality(activeQuality: 0.04)

        #expect(await context.emergencyKeyframeQuality() >= 0.14)

        await context.configureEmergencyKeyframeActiveQuality(activeQuality: 0.50)

        let readableRepairQuality = await context.emergencyKeyframeQuality()
        #expect(await !context.currentAwdlQualityReductionAllowed())
        #expect(readableRepairQuality >= 0.49)

        await context.setAwdlQualityReductionGateForTesting(
            allowed: true
        )
        let survivalRepairQuality = await context.emergencyKeyframeQuality()
        #expect(await context.currentAwdlQualityReductionAllowed())
        #expect(survivalRepairQuality < readableRepairQuality)
        #expect(survivalRepairQuality >= 0.14)
    }

    private func makeContext(
        streamID: StreamID,
        runtimeQualityAdjustmentEnabled: Bool = true,
        mediaPathProfile: MirageMediaPathProfile? = nil
    ) -> StreamContext {
        StreamContext(
            streamID: streamID,
            windowID: 9_001,
            encoderConfig: MirageEncoderConfiguration(
                targetFrameRate: 60,
                keyFrameInterval: 1_800,
                colorDepth: .standard,
                captureQueueDepth: 4,
                bitrate: 24_000_000
            ),
            runtimeQualityAdjustmentEnabled: runtimeQualityAdjustmentEnabled,
            capturePressureProfile: .baseline,
            latencyMode: .lowestLatency,
            mediaPathProfile: mediaPathProfile
        )
    }

    private func makeDisplaySnapshot() -> SharedVirtualDisplayManager.DisplaySnapshot {
        SharedVirtualDisplayManager.DisplaySnapshot(
            displayID: 47,
            spaceID: 1,
            resolution: CGSize(width: 3_200, height: 2_080),
            scaleFactor: 2.0,
            refreshRate: 60,
            colorSpace: .sRGB,
            displayP3CoverageStatus: .unresolved,
            generation: 1,
            createdAt: Date()
        )
    }

    @MainActor
    private final class AwdlGeometryUpdateRecorder {
        private(set) var streamIDs: [StreamID] = []

        func record(_ streamID: StreamID) {
            streamIDs.append(streamID)
        }
    }

    private func awdlFeedback(
        sequence: UInt64,
        pFrameCompletionLatencyP95Ms: Double? = nil,
        latePFrameCount: UInt64? = nil
    ) -> ReceiverMediaFeedbackMessage {
        ReceiverMediaFeedbackMessage(
            streamID: 81,
            sequence: sequence,
            sentAtUptime: 0,
            targetFPS: 60,
            ackRanges: [],
            lostFrameCount: 0,
            discardedPacketCount: 0,
            jitterP95Ms: 0,
            jitterP99Ms: 0,
            queueEstimateFrames: 0,
            reassemblyBacklogFrames: 0,
            reassemblyBacklogKeyframes: 0,
            reassemblyBacklogBytes: 0,
            decodeBacklogFrames: 0,
            presentationBacklogFrames: 0,
            decodedFPS: 60,
            receivedFPS: 60,
            rendererAcceptedFPS: 60,
            rendererPresentedFPS: 60,
            recoveryState: .idle,
            pFrameCompletionLatencyP50Ms: nil,
            pFrameCompletionLatencyP95Ms: pFrameCompletionLatencyP95Ms,
            pFrameCompletionLatencyMaxMs: nil,
            latePFrameCount: latePFrameCount
        )
    }

    private func applyAwdlPressureFeedback(
        _ context: StreamContext,
        startSequence: UInt64 = 1
    ) async {
        await context.applyReceiverMediaFeedback(
            awdlFeedback(
                sequence: startSequence,
                pFrameCompletionLatencyP95Ms: 80,
                latePFrameCount: 4
            )
        )
        await context.applyReceiverMediaFeedback(
            awdlFeedback(
                sequence: startSequence + 1,
                pFrameCompletionLatencyP95Ms: 80,
                latePFrameCount: 4
            )
        )
        await context.applyReceiverMediaFeedback(
            awdlFeedback(
                sequence: startSequence + 2,
                pFrameCompletionLatencyP95Ms: 80,
                latePFrameCount: 4
            )
        )
        await context.applyReceiverMediaFeedback(
            awdlFeedback(
                sequence: startSequence + 3,
                pFrameCompletionLatencyP95Ms: 80,
                latePFrameCount: 4
            )
        )
    }
}

private extension StreamContext {
    func configureForDedicatedVirtualDisplayTest(
        baseCaptureSize: CGSize,
        windowFrame: CGRect,
        displaySnapshot: SharedVirtualDisplayManager.DisplaySnapshot,
        visibleBounds: CGRect
    ) {
        isRunning = true
        useVirtualDisplay = true
        captureMode = .window
        virtualDisplayContext = displaySnapshot
        virtualDisplayVisibleBounds = visibleBounds
        virtualDisplayCaptureSourceRect = visibleBounds
        self.baseCaptureSize = baseCaptureSize
        currentCaptureSize = baseCaptureSize
        currentEncodedSize = baseCaptureSize
        lastWindowFrame = windowFrame
        streamScale = 1.0
        requestedStreamScale = 1.0
    }

    func configureEmergencyKeyframeActiveQuality(activeQuality: Float) {
        self.activeQuality = activeQuality
        qualityCeiling = resolvedQualityCeiling
        qualityFloor = resolvedRuntimeQualityFloor(for: qualityCeiling)
        keyframeQualityFloor = resolvedRuntimeKeyframeQualityFloor(for: qualityCeiling)
    }

    func setAwdlQualityReductionGateForTesting(
        allowed: Bool
    ) {
        if allowed {
            awdlHostEncoderStructuralQualityReductionAllowed = true
            awdlHostEncoderStructuralQualityReductionDeadline = CFAbsoluteTimeGetCurrent() + 60
        } else {
            clearAwdlHostStructuralQualityReduction()
        }
    }
}
#endif
