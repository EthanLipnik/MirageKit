//
//  StreamContext+CustomStreaming.swift
//  MirageKit
//
//  Created by Codex on 4/30/26.
//

import CoreMedia
import Foundation
import MirageKit

#if os(macOS)

extension StreamContext {
    func startCustomFrameStream(
        pixelSize: CGSize,
        sendPacket: @escaping @Sendable (Data, @escaping @Sendable (Error?) -> Void) -> Void,
        onSendError: (@Sendable (Error) -> Void)? = nil
    )
    async throws -> MirageCustomStreamFrameSink {
        guard !isRunning else {
            return makeCustomFrameSink()
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

        await setupPacketSender(sendPacket: sendPacket, onSendError: onSendError)

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

        MirageLogger.stream("Started custom stream \(streamID) at \(width)x\(height)")
        return makeCustomFrameSink()
    }

    private func makeCustomFrameSink() -> MirageCustomStreamFrameSink {
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
