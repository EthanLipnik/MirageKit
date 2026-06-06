//
//  StreamContext+Streaming+Starts.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Standard stream startup paths.
//

import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageKit
import MirageKitClientPresentation
import MirageMedia
import MirageWire
import CoreVideo
import Foundation

#if os(macOS)
import ScreenCaptureKit

extension StreamContext {
    func startMirroredAppWindowCapture(
        applicationWrapper: SCApplicationWrapper,
        displayWrapper: SCDisplayWrapper,
        mirroredDisplaySnapshot: MirageHostVirtualDisplaySnapshot,
        sizePreset: MirageMedia.MirageDisplaySizePreset,
        clientLogicalSize: CGSize,
        sendPacketWithMetadata: @escaping StreamPacketSender.PacketMetadataSendHandler,
        onSendError: (@Sendable (Error) -> Void)? = nil
    )
    async throws {
        try await startSharedDisplayWindowCapture(
            applicationWrapper: applicationWrapper,
            displayWrapper: displayWrapper,
            mirroredDisplaySnapshot: mirroredDisplaySnapshot,
            sizePreset: sizePreset,
            clientLogicalSize: clientLogicalSize,
            sendPacketWithMetadata: sendPacketWithMetadata,
            onSendError: onSendError
        )
    }

    func startDesktopDisplay(
        displayWrapper: SCDisplayWrapper,
        resolution: CGSize? = nil,
        excludedWindows: [SCWindowWrapper] = [],
        sendPacketWithMetadata: @escaping StreamPacketSender.PacketMetadataSendHandler,
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

        await setupPacketSender(
            sendPacketWithMetadata: sendPacketWithMetadata,
            onSendError: onSendError
        )

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

        let pinDesktopContentRectToFullFrame = virtualDisplayBackend.isMirageDisplay(display.displayID)
        let pinnedRect: CGRect? = pinDesktopContentRectToFullFrame
            ? CGRect(x: 0, y: 0, width: outputSize.width, height: outputSize.height)
            : nil
        await startEncoderWithSharedCallback(pinnedContentRect: pinnedRect, logPrefix: "Desktop frame")

        let isMirageDisplay = virtualDisplayBackend.isMirageDisplay(display.displayID)
        let usesDisplayRefreshCadence = desktopCaptureUsesDisplayRefreshCadenceOverride ?? isMirageDisplay
        let captureEngine = try await setupAndStartCaptureEngine(usesDisplayRefreshCadence: usesDisplayRefreshCadence)
        let captureSizeForSCK = resolution == nil ? nil : outputSize
        let excludedWindowIDs = excludedWindows.map { WindowID($0.window.windowID) }
        let captureSourceBackend = makeCaptureSourceBackend()
        try await captureSourceBackend.startCapture(
            desktopDisplayCaptureRequest(
                displayID: display.displayID,
                outputSize: outputSize,
                captureResolution: captureSizeForSCK,
                excludedWindowIDs: excludedWindowIDs
            ),
            using: captureEngine,
            onFrame: { [weak self] frame in
                self?.enqueueCapturedFrame(frame)
            },
            onAudio: onCapturedAudioBuffer
        )
        await refreshCaptureCadence()

        MirageLogger.stream(streamBoundaryLog(phase: "start", kind: "desktop", width: width, height: height))
        MirageLogger.stream("Started desktop display stream \(streamID) at \(width)x\(height)")
    }

    func desktopDisplayCaptureRequest(
        displayID: CGDirectDisplayID,
        outputSize: CGSize,
        captureResolution: CGSize?,
        excludedWindowIDs: [WindowID]
    ) -> MirageHostCaptureRequest {
        let source: MirageHostCaptureSource = excludedWindowIDs.isEmpty
            ? .display(MirageHostDisplayID(displayID))
            : .displayWindowSet(
                displayID: MirageHostDisplayID(displayID),
                includedWindowIDs: [],
                excludedWindowIDs: excludedWindowIDs
            )
        return displayCaptureRequest(
            source: source,
            outputSize: outputSize,
            captureResolution: captureResolution,
            sourceRect: nil,
            destinationRect: nil,
            contentWindowID: nil,
            showsCursor: captureShowsCursor
        )
    }

    func appStreamDisplayCaptureRequest(
        displayID: CGDirectDisplayID,
        outputSize: CGSize,
        destinationRect: CGRect?
    ) -> MirageHostCaptureRequest {
        displayCaptureRequest(
            source: .display(MirageHostDisplayID(displayID)),
            outputSize: outputSize,
            captureResolution: outputSize,
            sourceRect: nil,
            destinationRect: destinationRect,
            contentWindowID: nil,
            showsCursor: false
        )
    }

    func sharedDisplayWindowCaptureRequest(
        displayID: CGDirectDisplayID,
        outputSize: CGSize,
        sourceRect: CGRect,
        destinationRect: CGRect,
        contentWindowID: WindowID,
        includedWindowIDs: [WindowID]
    ) -> MirageHostCaptureRequest {
        displayCaptureRequest(
            source: .displayWindowSet(
                displayID: MirageHostDisplayID(displayID),
                includedWindowIDs: includedWindowIDs,
                excludedWindowIDs: []
            ),
            outputSize: outputSize,
            captureResolution: outputSize,
            sourceRect: sourceRect,
            destinationRect: destinationRect,
            contentWindowID: contentWindowID,
            showsCursor: false
        )
    }

    private func displayCaptureRequest(
        source: MirageHostCaptureSource,
        outputSize: CGSize,
        captureResolution: CGSize?,
        sourceRect: CGRect?,
        destinationRect: CGRect?,
        contentWindowID: WindowID?,
        showsCursor: Bool
    ) -> MirageHostCaptureRequest {
        let capturesAudio = onCapturedAudioBuffer != nil
        return MirageHostCaptureRequest(
            source: source,
            configuration: MirageHostCaptureConfiguration(
                logicalSize: outputSize,
                captureResolution: captureResolution,
                sourceRect: sourceRect,
                destinationRect: destinationRect,
                contentWindowID: contentWindowID,
                showsCursor: showsCursor,
                targetFrameRate: currentFrameRate,
                queueDepth: encoderConfig.captureQueueDepth ?? 1,
                capturesAudio: capturesAudio,
                audioConfiguration: MirageMedia.MirageAudioConfiguration(enabled: capturesAudio),
                audioChannelCount: requestedAudioChannelCount
            )
        )
    }

    func startAppStreamDisplayCapture(
        displayWrapper: SCDisplayWrapper,
        mirroredDisplaySnapshot: MirageHostVirtualDisplaySnapshot,
        sendPacketWithMetadata: @escaping StreamPacketSender.PacketMetadataSendHandler,
        onSendError: (@Sendable (Error) -> Void)? = nil
    )
    async throws {
        guard !isRunning else { return }
        isRunning = true
        useVirtualDisplay = true
        captureFrameRateOverride = currentFrameRate
        captureFrameRate = currentFrameRate

        isAppStream = true
        applicationProcessID = 0
        appStreamBundleIdentifier = nil
        trafficLightMaskGeometryCache = nil
        lastTrafficLightMaskLogTime = 0
        virtualDisplayContext = mirroredDisplaySnapshot

        await setupPacketSender(
            sendPacketWithMetadata: sendPacketWithMetadata,
            onSendError: onSendError
        )

        let captureResolution = mirroredDisplaySnapshot.resolution
        baseCaptureSize = captureResolution
        streamScale = 1.0
        let outputSize = captureResolution
        currentCaptureSize = outputSize
        currentEncodedSize = outputSize
        let fullOutputRect = CGRect(origin: .zero, size: outputSize)
        let captureSourceRect = CGRect(
            x: 0,
            y: 0,
            width: max(1, CGFloat(displayWrapper.display.width)),
            height: max(1, CGFloat(displayWrapper.display.height))
        )
        let captureDestinationRect = Self.fixedCanvasDestinationRect(
            sourceRect: captureSourceRect,
            outputSize: outputSize
        )
        let usesFullOutputRect = captureDestinationRect.equalTo(fullOutputRect)
        currentContentRect = usesFullOutputRect ? fullOutputRect : captureDestinationRect
        captureMode = .display
        updateQueueLimits()
        await applyDerivedQuality(for: outputSize, logLabel: "App-stream display init")
        let width = max(1, Int(outputSize.width.rounded()))
        let height = max(1, Int(outputSize.height.rounded()))
        MirageLogger.stream(
            "App-stream display encoding at \(width)x\(height) " +
                "(latency=\(latencyMode.displayName), queue=\(maxQueuedBytes / 1024)KB)"
        )

        try await createAndPreheatEncoder(streamKind: .appAtlas, width: width, height: height)
        let pinnedRect = currentContentRect
        await startEncoderWithSharedCallback(pinnedContentRect: pinnedRect, logPrefix: "App-stream display frame")

        let captureEngine = try await setupAndStartCaptureEngine(usesDisplayRefreshCadence: true)
        let captureSourceBackend = makeCaptureSourceBackend()
        try await captureSourceBackend.startCapture(
            appStreamDisplayCaptureRequest(
                displayID: displayWrapper.display.displayID,
                outputSize: outputSize,
                destinationRect: usesFullOutputRect ? nil : captureDestinationRect
            ),
            using: captureEngine,
            onFrame: { [weak self] frame in
                self?.enqueueCapturedFrame(frame)
            },
            onAudio: onCapturedAudioBuffer
        )
        await refreshCaptureCadence()

        MirageLogger.stream(streamBoundaryLog(phase: "start", kind: "app-stream-display", width: width, height: height))
        MirageLogger.stream(
            "Started app-stream display stream \(streamID) capturing display \(displayWrapper.display.displayID) " +
                "into shared display geometry \(mirroredDisplaySnapshot.displayID)"
        )
    }
}

#endif
