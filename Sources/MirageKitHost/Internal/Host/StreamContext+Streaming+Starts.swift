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
    func start(
        windowWrapper: SCWindowWrapper,
        applicationWrapper: SCApplicationWrapper,
        displayWrapper: SCDisplayWrapper,
        onEncodedFrame: @escaping @Sendable (Data, FrameHeader, @escaping @Sendable () -> Void) -> Void
    )
    async throws {
        guard !isRunning else { return }
        isRunning = true
        useVirtualDisplay = false
        captureFrameRateOverride = currentFrameRate
        captureFrameRate = currentFrameRate

        let window = windowWrapper.window
        let application = applicationWrapper.application
        let display = displayWrapper.display
        isAppStream = true
        applicationProcessID = application.processID
        trafficLightMaskGeometryCache = nil
        lastTrafficLightMaskLogTime = 0

        await setupPacketSender(onEncodedFrame: onEncodedFrame)

        let captureTarget = streamTargetDimensions(windowFrame: window.frame)
        baseCaptureSize = CGSize(width: captureTarget.width, height: captureTarget.height)
        streamScale = resolvedStreamScale(
            for: baseCaptureSize,
            requestedScale: requestedStreamScale,
            logLabel: "Resolution cap"
        )
        let outputSize = scaledOutputSize(for: baseCaptureSize)
        currentCaptureSize = outputSize
        currentEncodedSize = outputSize
        captureMode = .window
        lastWindowFrame = window.frame
        updateQueueLimits()
        await applyDerivedQuality(for: outputSize, logLabel: "Stream init")
        MirageLogger.stream(
            "Stream init: latency=\(latencyMode.displayName), scale=\(streamScale), encoded=\(Int(outputSize.width))x\(Int(outputSize.height)), queue=\(maxQueuedBytes / 1024)KB, buffer=\(frameBufferDepth)"
        )

        try await createAndPreheatEncoder(
            streamKind: .window,
            width: Int(outputSize.width),
            height: Int(outputSize.height)
        )

        await startEncoderWithSharedCallback(pinnedContentRect: nil, logPrefix: "Frame")

        let captureEngine = await setupAndStartCaptureEngine(usesDisplayRefreshCadence: false)
        try await captureEngine.startCapture(
            window: window,
            application: application,
            display: display,
            outputScale: streamScale,
            onFrame: { [weak self] frame in
                self?.enqueueCapturedFrame(frame)
            },
            onAudio: onCapturedAudioBuffer,
            audioChannelCount: requestedAudioChannelCount
        )
        await refreshCaptureCadence()

        MirageLogger.stream("Started stream \(streamID) for window \(windowID)")
    }

    func startDesktopDisplay(
        displayWrapper: SCDisplayWrapper,
        resolution: CGSize? = nil,
        excludedWindows: [SCWindowWrapper] = [],
        onEncodedFrame: @escaping @Sendable (Data, FrameHeader, @escaping @Sendable () -> Void) -> Void
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

        await setupPacketSender(onEncodedFrame: onEncodedFrame)

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
        let captureEngine = await setupAndStartCaptureEngine(usesDisplayRefreshCadence: isMirageDisplay)
        let resolvedExcludedWindows = excludedWindows.map(\.window)
        let captureSizeForSCK = isMirageDisplay ? outputSize : nil
        try await captureEngine.startDisplayCapture(
            display: display,
            resolution: captureSizeForSCK,
            excludedWindows: resolvedExcludedWindows,
            showsCursor: false,
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
