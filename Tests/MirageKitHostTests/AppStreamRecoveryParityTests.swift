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

    @Test("Window streaming preparation adds a short settle after plain activation")
    func windowStreamingPreparationAddsActivationSettleDelay() {
        let plan = MirageHostService.windowStreamingPreparationPlan(
            isOnScreen: true,
            isFullScreen: false
        )

        #expect(plan.shouldRestoreWindow == false)
        #expect(plan.shouldExitFullScreen == false)
        #expect(plan.settleDelayMilliseconds == 150)
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

        #expect(abs((await context.getStreamScale()) - 0.8) < 0.001)
        #expect(await context.getDimensionToken() == 1)

        let encodedDimensions = await context.getEncodedDimensions()
        #expect(encodedDimensions.width == 2_560)
        #expect(encodedDimensions.height == 1_664)
    }

    private func makeContext(streamID: StreamID) -> StreamContext {
        StreamContext(
            streamID: streamID,
            windowID: 9_001,
            encoderConfig: MirageEncoderConfiguration(
                targetFrameRate: 60,
                keyFrameInterval: 1_800,
                bitDepth: .eightBit,
                captureQueueDepth: 4,
                bitrate: 24_000_000
            ),
            runtimeQualityAdjustmentEnabled: true,
            lowLatencyHighResolutionCompressionBoostEnabled: true,
            capturePressureProfile: .baseline,
            latencyMode: .lowestLatency,
            performanceMode: .standard
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
        virtualDisplayVisiblePixelResolution = displaySnapshot.resolution
        self.baseCaptureSize = baseCaptureSize
        currentCaptureSize = baseCaptureSize
        currentEncodedSize = baseCaptureSize
        lastWindowFrame = windowFrame
        streamScale = 1.0
        requestedStreamScale = 1.0
    }
}
#endif
