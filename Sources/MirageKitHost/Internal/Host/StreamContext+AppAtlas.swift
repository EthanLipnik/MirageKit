//
//  StreamContext+AppAtlas.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/3/26.
//

import CoreMedia
import Foundation
import MirageKit

#if os(macOS)
extension StreamContext {
    func startAppAtlasFrameStream(
        pixelSize: CGSize,
        sendPacket: @escaping @Sendable (Data, @escaping @Sendable (Error?) -> Void) -> Void,
        onSendError: (@Sendable (Error) -> Void)? = nil
    )
    async throws -> MirageCustomStreamFrameSink {
        guard !isRunning else {
            return makeCustomStreamFrameSink()
        }

        let outputSize = normalizedAppAtlasPixelSize(pixelSize)
        isRunning = true
        useVirtualDisplay = false
        captureMode = .window
        captureFrameRateOverride = currentFrameRate
        captureFrameRate = currentFrameRate
        isAppStream = true
        applicationProcessID = 0
        trafficLightMaskGeometryCache = nil
        lastTrafficLightMaskLogTime = 0

        await setupPacketSender(sendPacket: sendPacket, onSendError: onSendError)

        streamScale = 1.0
        baseCaptureSize = outputSize
        currentCaptureSize = outputSize
        currentEncodedSize = outputSize
        currentContentRect = CGRect(origin: .zero, size: outputSize)
        updateQueueLimits()
        await applyDerivedQuality(for: outputSize, logLabel: "App atlas init")

        try await createAndPreheatEncoder(
            streamKind: .appAtlas,
            width: Int(outputSize.width),
            height: Int(outputSize.height)
        )
        await startEncoderWithSharedCallback(
            pinnedContentRect: CGRect(origin: .zero, size: outputSize),
            logPrefix: "App atlas frame"
        )

        MirageLogger.stream(
            "Started app atlas stream \(streamID) at \(Int(outputSize.width))x\(Int(outputSize.height))"
        )
        return makeCustomStreamFrameSink()
    }

    func applyAppAtlasDimensionsIfNeeded(pixelSize: CGSize) async throws {
        let outputSize = normalizedAppAtlasPixelSize(pixelSize)
        guard outputSize != currentEncodedSize else { return }

        try await applyAppAtlasDimensions(outputSize)
    }

    private func applyAppAtlasDimensions(_ outputSize: CGSize) async throws {
        dimensionToken &+= 1
        MirageLogger.stream("Dimension token incremented to \(dimensionToken)")
        await packetSender?.bumpGeneration(reason: "app atlas resize")
        resetPipelineStateForReconfiguration(reason: "app atlas resize")

        baseCaptureSize = outputSize
        currentCaptureSize = outputSize
        currentEncodedSize = outputSize
        currentContentRect = CGRect(origin: .zero, size: outputSize)
        updateQueueLimits()

        if let encoder {
            try await encoder.updateDimensions(width: Int(outputSize.width), height: Int(outputSize.height))
        }
        await applyDerivedQuality(for: outputSize, logLabel: "App atlas resize")
        await encoder?.forceKeyframe()

        MirageLogger.stream(
            "App atlas stream \(streamID) resized to \(Int(outputSize.width))x\(Int(outputSize.height))"
        )
    }

    private func normalizedAppAtlasPixelSize(_ size: CGSize) -> CGSize {
        CGSize(
            width: CGFloat(Self.normalizedAppAtlasPixelLength(size.width)),
            height: CGFloat(Self.normalizedAppAtlasPixelLength(size.height))
        )
    }

    private nonisolated static func normalizedAppAtlasPixelLength(_ value: CGFloat) -> Int {
        guard value.isFinite, value > 0 else { return 16 }
        let rounded = max(1, Int(ceil(value)))
        return max(16, ((rounded + 15) / 16) * 16)
    }
}
#endif
