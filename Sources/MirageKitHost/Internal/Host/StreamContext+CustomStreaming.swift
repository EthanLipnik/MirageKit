//
//  StreamContext+CustomStreaming.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/30/26.
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
import CoreMedia
import Foundation

#if os(macOS)

extension StreamContext {
    func startCustomFrameStream(
        pixelSize: CGSize,
        sendPacketWithMetadata: @escaping StreamPacketSender.PacketMetadataSendHandler,
        onSendError: (@Sendable (Error) -> Void)? = nil
    )
    async throws -> MirageCustomStreamFrameSink {
        guard !isRunning else {
            return makeCustomStreamFrameSink()
        }

        isRunning = true
        useVirtualDisplay = false
        captureMode = .display
        captureFrameRateOverride = currentFrameRate
        captureFrameRate = currentFrameRate
        isAppStream = false
        applicationProcessID = 0
        trafficLightMaskGeometryCache = nil
        lastTrafficLightMaskLogTime = 0

        await setupPacketSender(
            sendPacketWithMetadata: sendPacketWithMetadata,
            onSendError: onSendError
        )

        baseCaptureSize = pixelSize
        streamScale = resolvedStreamScale(
            for: baseCaptureSize,
            requestedScale: requestedStreamScale,
            logLabel: "Custom stream resolution cap"
        )
        let outputSize = scaledOutputSize(for: baseCaptureSize)
        currentCaptureSize = outputSize
        currentEncodedSize = outputSize
        currentContentRect = CGRect(x: 0, y: 0, width: outputSize.width, height: outputSize.height)
        updateQueueLimits()
        await applyDerivedQuality(for: outputSize, logLabel: "Custom stream init")

        let width = max(1, Int(outputSize.width))
        let height = max(1, Int(outputSize.height))
        try await createAndPreheatEncoder(streamKind: .custom, width: width, height: height)
        await startEncoderWithSharedCallback(
            pinnedContentRect: CGRect(x: 0, y: 0, width: outputSize.width, height: outputSize.height),
            logPrefix: "Custom frame"
        )

        MirageLogger.stream(streamBoundaryLog(phase: "start", kind: "custom", width: width, height: height))
        MirageLogger.stream("Started custom stream \(streamID) at \(width)x\(height)")
        return makeCustomStreamFrameSink()
    }

    /// Creates a frame sink that forwards supplied custom frames into this stream context.
    func makeCustomStreamFrameSink() -> MirageCustomStreamFrameSink {
        MirageCustomStreamFrameSink { [weak self] frame in
            guard let self else { return }
            let info = CapturedFrameInfo(
                contentRect: frame.contentRect,
                dirtyPercentage: frame.dirtyPercentage,
                isIdleFrame: frame.isIdleFrame
            )
            let capturedFrame = CapturedFrame(
                pixelBuffer: frame.pixelBuffer,
                presentationTime: frame.presentationTime,
                duration: frame.duration,
                captureTime: CFAbsoluteTimeGetCurrent(),
                info: info
            )
            self.enqueueCapturedFrame(capturedFrame)
        }
    }
}

#endif
