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
    @Test("Emergency recovery scale keeps dimension token stable")
    func emergencyRecoveryScaleKeepsDimensionTokenStable() async throws {
        let context = makeContext(streamID: 78)
        await context.configureForDedicatedVirtualDisplayTest(
            baseCaptureSize: CGSize(width: 2_048, height: 1_536),
            windowFrame: CGRect(x: 0, y: 0, width: 1_024, height: 768),
            displaySnapshot: makeDisplaySnapshot(),
            visibleBounds: CGRect(x: 0, y: 0, width: 1_024, height: 768)
        )
        let initialToken = await context.streamStartSnapshot.dimensionToken

        try await context.updateEmergencyRecoveryScale(0.75, reason: "test")

        #expect(await context.streamStartSnapshot.dimensionToken == initialToken)
        #expect(abs((await context.streamScale) - 0.75) < 0.001)
        #expect(abs((await context.requestedStreamScale) - 1.0) < 0.001)
        let recoveryDimensions = await context.encodedDimensions
        #expect(recoveryDimensions.width == 1_536)
        #expect(recoveryDimensions.height == 1_152)

        try await context.updateStreamScale(0.5)

        #expect(await context.streamStartSnapshot.dimensionToken == initialToken &+ 1)
    }

    @MainActor
    @Test("AWDL interactive scale advances dimension token")
    func awdlInteractiveScaleAdvancesDimensionToken() async throws {
        let context = makeContext(streamID: 80, mediaPathProfile: .awdlRadio)
        await context.configureForDedicatedVirtualDisplayTest(
            baseCaptureSize: CGSize(width: 2_752, height: 2_064),
            windowFrame: CGRect(x: 0, y: 0, width: 1_376, height: 1_032),
            displaySnapshot: makeDisplaySnapshot(),
            visibleBounds: CGRect(x: 0, y: 0, width: 1_376, height: 1_032)
        )
        let initialToken = await context.streamStartSnapshot.dimensionToken

        try await context.updateEmergencyRecoveryScale(
            0.875,
            reason: "awdl-interactive",
            advancesDimensionToken: true
        )

        #expect(await context.streamStartSnapshot.dimensionToken == initialToken &+ 1)
        #expect(abs((await context.streamScale) - 0.875) < 0.001)
        let recoveryDimensions = await context.encodedDimensions
        #expect(recoveryDimensions.width == 2_384)
        #expect(recoveryDimensions.height == 1_792)
    }

    @MainActor
    @Test("AWDL interactive feedback scale announces desktop geometry")
    func awdlInteractiveFeedbackScaleAnnouncesDesktopGeometry() async {
        let context = makeContext(streamID: 82, mediaPathProfile: .awdlRadio)
        await context.configureForDedicatedVirtualDisplayTest(
            baseCaptureSize: CGSize(width: 2_752, height: 2_064),
            windowFrame: CGRect(x: 0, y: 0, width: 1_376, height: 1_032),
            displaySnapshot: makeDisplaySnapshot(),
            visibleBounds: CGRect(x: 0, y: 0, width: 1_376, height: 1_032)
        )
        let recorder = AwdlGeometryUpdateRecorder()
        await context.setAwdlInteractiveDesktopGeometryUpdateHandler { streamID in
            recorder.record(streamID)
        }

        await applyAwdlFeedbackThroughResolutionDemotion(context)

        #expect(recorder.streamIDs == [82, 82, 82])
        #expect(abs((await context.streamScale) - 0.875) < 0.001)
    }

    @MainActor
    @Test("AWDL interactive feedback frame-rate step announces desktop cadence")
    func awdlInteractiveFeedbackFrameRateStepAnnouncesDesktopCadence() async {
        let context = makeContext(streamID: 83, mediaPathProfile: .awdlRadio)
        await context.configureForDedicatedVirtualDisplayTest(
            baseCaptureSize: CGSize(width: 2_752, height: 2_064),
            windowFrame: CGRect(x: 0, y: 0, width: 1_376, height: 1_032),
            displaySnapshot: makeDisplaySnapshot(),
            visibleBounds: CGRect(x: 0, y: 0, width: 1_376, height: 1_032)
        )
        let initialToken = await context.streamStartSnapshot.dimensionToken
        let recorder = AwdlGeometryUpdateRecorder()
        await context.setAwdlInteractiveDesktopGeometryUpdateHandler { streamID in
            recorder.record(streamID)
        }

        for sequence in 1...2 {
            await context.applyReceiverMediaFeedback(
                awdlFeedback(
                    sequence: UInt64(sequence),
                    pFrameCompletionLatencyP95Ms: 80,
                    latePFrameCount: 4
                )
            )
        }

        #expect(recorder.streamIDs == [83])
        #expect(context.currentFrameRate == 45)
        #expect(await context.streamStartSnapshot.targetFrameRate == 45)
        #expect(await context.streamStartSnapshot.dimensionToken == initialToken)
        #expect(abs((await context.streamScale) - 1.0) < 0.001)
    }

    @MainActor
    @Test("AWDL interactive scale restore retries after cooldown")
    func awdlInteractiveScaleRestoreRetriesAfterCooldown() async {
        let context = makeContext(streamID: 81, mediaPathProfile: .awdlRadio)
        await context.configureForDedicatedVirtualDisplayTest(
            baseCaptureSize: CGSize(width: 2_752, height: 2_064),
            windowFrame: CGRect(x: 0, y: 0, width: 1_376, height: 1_032),
            displaySnapshot: makeDisplaySnapshot(),
            visibleBounds: CGRect(x: 0, y: 0, width: 1_376, height: 1_032)
        )
        let initialToken = await context.streamStartSnapshot.dimensionToken

        await applyAwdlFeedbackThroughResolutionDemotion(context)

        #expect(abs((await context.streamScale) - 0.875) < 0.001)
        #expect(await context.streamStartSnapshot.dimensionToken == initialToken &+ 1)

        for sequence in 5...7 {
            await context.applyReceiverMediaFeedback(awdlFeedback(sequence: UInt64(sequence)))
        }

        #expect(abs((await context.streamScale) - 0.875) < 0.001)
        #expect(await context.streamStartSnapshot.dimensionToken == initialToken &+ 1)

        await context.forceAwdlInteractiveScaleCooldownForTest(secondsAgo: 21)
        await context.applyReceiverMediaFeedback(awdlFeedback(sequence: 8))

        #expect(abs((await context.streamScale) - 1.0) < 0.001)
        #expect(await context.streamStartSnapshot.dimensionToken == initialToken &+ 2)
    }

    @MainActor
    @Test("AWDL interactive demotion remains active when runtime quality is disabled")
    func awdlInteractiveDemotionRemainsActiveWhenRuntimeQualityIsDisabled() async {
        let context = makeContext(
            streamID: 81,
            runtimeQualityAdjustmentEnabled: false,
            mediaPathProfile: .awdlRadio
        )
        await context.configureForDedicatedVirtualDisplayTest(
            baseCaptureSize: CGSize(width: 2_752, height: 2_064),
            windowFrame: CGRect(x: 0, y: 0, width: 1_376, height: 1_032),
            displaySnapshot: makeDisplaySnapshot(),
            visibleBounds: CGRect(x: 0, y: 0, width: 1_376, height: 1_032)
        )
        let initialToken = await context.streamStartSnapshot.dimensionToken

        await applyAwdlFeedbackThroughResolutionDemotion(context)

        #expect(abs((await context.streamScale) - 0.875) < 0.001)
        #expect(await context.streamStartSnapshot.dimensionToken == initialToken &+ 1)
    }

    @MainActor
    @Test("AWDL emergency keyframes honor interactive quality floor")
    func awdlEmergencyKeyframesHonorInteractiveQualityFloor() async {
        let context = makeContext(streamID: 79, mediaPathProfile: .awdlRadio)
        await context.configureEmergencyKeyframeQualityTest(activeQuality: 0.04)

        #expect(await context.emergencyKeyframeQuality() >= 0.14)

        await context.configureEmergencyKeyframeQualityTest(activeQuality: 0.50)

        let readableRepairQuality = await context.emergencyKeyframeQuality()
        #expect(await !context.currentAwdlQualityReductionAllowed())
        #expect(readableRepairQuality >= 0.49)

        await context.setAwdlQualityReductionGateForTesting(
            frameRate: 30,
            streamScale: 0.75,
            baseScale: 1.0,
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
            lowLatencyHighResolutionCompressionBoostEnabled: true,
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

    private func applyAwdlFeedbackThroughResolutionDemotion(
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
        await context.forceAwdlInteractiveFrameRateCooldownForTest(secondsAgo: 2)
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

    func configureEmergencyKeyframeQualityTest(activeQuality: Float) {
        self.activeQuality = activeQuality
        qualityCeiling = resolvedQualityCeiling
        qualityFloor = resolvedRuntimeQualityFloor(for: qualityCeiling)
        keyframeQualityFloor = resolvedRuntimeKeyframeQualityFloor(for: qualityCeiling)
    }

    func forceAwdlInteractiveScaleCooldownForTest(secondsAgo: CFAbsoluteTime) {
        lastAwdlInteractiveScaleAdjustmentTime = max(0, CFAbsoluteTimeGetCurrent() - secondsAgo)
    }

    func forceAwdlInteractiveFrameRateCooldownForTest(secondsAgo: CFAbsoluteTime) {
        lastAwdlInteractiveFrameRateAdjustmentTime = max(0, CFAbsoluteTimeGetCurrent() - secondsAgo)
    }

    func setAwdlQualityReductionGateForTesting(
        frameRate: Int,
        streamScale: CGFloat,
        baseScale: CGFloat,
        allowed: Bool
    ) {
        currentFrameRate = frameRate
        self.streamScale = streamScale
        awdlInteractiveBaseStreamScale = baseScale
        if allowed {
            awdlHostEncoderStructuralQualityReductionAllowed = true
            awdlHostEncoderStructuralQualityReductionDeadline = CFAbsoluteTimeGetCurrent() + 60
        } else {
            clearAwdlHostStructuralQualityReduction()
        }
    }
}
#endif
