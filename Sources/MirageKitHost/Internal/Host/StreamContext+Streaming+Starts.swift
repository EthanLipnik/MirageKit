//
//  StreamContext+Streaming+Starts.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Standard stream startup paths.
//

import CoreVideo
import Foundation
import MirageKit

#if os(macOS)
import ScreenCaptureKit

extension StreamContext {
    func startMirroredAppWindowCapture(
        windowWrapper: SCWindowWrapper,
        applicationWrapper: SCApplicationWrapper,
        displayWrapper: SCDisplayWrapper,
        mirroredDisplaySnapshot: SharedVirtualDisplayManager.DisplaySnapshot,
        sizePreset: MirageDisplaySizePreset,
        clientLogicalSize: CGSize,
        sendPacket: @escaping @Sendable (Data, @escaping @Sendable (Error?) -> Void) -> Void,
        onSendError: (@Sendable (Error) -> Void)? = nil
    )
    async throws {
        try await startSharedDisplayWindowCapture(
            windowWrapper: windowWrapper,
            applicationWrapper: applicationWrapper,
            displayWrapper: displayWrapper,
            mirroredDisplaySnapshot: mirroredDisplaySnapshot,
            sizePreset: sizePreset,
            clientLogicalSize: clientLogicalSize,
            sendPacket: sendPacket,
            onSendError: onSendError
        )
    }

    func startDesktopDisplay(
        displayWrapper: SCDisplayWrapper,
        resolution: CGSize? = nil,
        excludedWindows: [SCWindowWrapper] = [],
        sendPacket: @escaping @Sendable (Data, @escaping @Sendable (Error?) -> Void) -> Void,
        onSendError: (@Sendable (Error) -> Void)? = nil
    )
    async throws {
        guard !isRunning else { return }
        isRunning = true
        useVirtualDisplay = false
        captureFrameRateOverride = currentFrameRate
        captureFrameRate = currentFrameRate

        let display = displayWrapper.display
        isAppStream = false
        applicationProcessID = 0
        trafficLightMaskGeometryCache = nil
        lastTrafficLightMaskLogTime = 0

        await setupPacketSender(sendPacket: sendPacket, onSendError: onSendError)

        let captureResolution = resolution ?? CGSize(width: display.width, height: display.height)
        baseCaptureSize = captureResolution
        streamScale = resolvedStreamScale(
            for: baseCaptureSize,
            requestedScale: requestedStreamScale,
            logLabel: "Resolution cap"
        )
        let outputSize = scaledOutputSize(for: baseCaptureSize)
        currentCaptureSize = outputSize
        currentEncodedSize = outputSize
        captureMode = .display
        updateQueueLimits()
        await applyDerivedQuality(for: outputSize, logLabel: "Desktop init")
        let width = max(1, Int(outputSize.width))
        let height = max(1, Int(outputSize.height))
        MirageLogger.stream(
            "Desktop encoding at \(width)x\(height) (latency=\(latencyMode.displayName), scale=\(streamScale), queue=\(maxQueuedBytes / 1024)KB)"
        )

        try await createAndPreheatEncoder(streamKind: .desktop, width: width, height: height)

        let pinDesktopContentRectToFullFrame = CGVirtualDisplayBridge.isMirageDisplay(display.displayID)
        let pinnedRect: CGRect? = pinDesktopContentRectToFullFrame
            ? CGRect(x: 0, y: 0, width: outputSize.width, height: outputSize.height)
            : nil
        await startEncoderWithSharedCallback(pinnedContentRect: pinnedRect, logPrefix: "Desktop frame")

        let isMirageDisplay = CGVirtualDisplayBridge.isMirageDisplay(display.displayID)
        let captureEngine = try await setupAndStartCaptureEngine(usesDisplayRefreshCadence: isMirageDisplay)
        let resolvedExcludedWindows = excludedWindows.map(\.window)
        let captureSizeForSCK = isMirageDisplay ? outputSize : nil
        try await captureEngine.startDisplayCapture(
            display: display,
            resolution: captureSizeForSCK,
            excludedWindows: resolvedExcludedWindows,
            showsCursor: captureShowsCursor,
            onFrame: { [weak self] frame in
                self?.enqueueCapturedFrame(frame)
            },
            onAudio: onCapturedAudioBuffer,
            audioChannelCount: requestedAudioChannelCount
        )
        await refreshCaptureCadence()

        MirageLogger.stream("Started desktop display stream \(streamID) at \(width)x\(height)")
    }
}

#endif
