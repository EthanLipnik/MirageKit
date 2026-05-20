//
//  MirageClientService+AutomaticDesktopWorkload.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/12/26.
//
//  Client-driven automatic desktop workload reconfiguration.
//

import CoreGraphics
import Foundation
import MirageKit

@MainActor
extension MirageClientService {
    /// Requests a host-side desktop workload tier change for the active desktop stream.
    public func requestAutomaticDesktopWorkloadReconfiguration(
        streamID: StreamID,
        target: MirageAutomaticDesktopWorkloadTier
    )
    async throws -> Bool {
        guard case .connected = connectionState else { throw MirageError.protocolError("Not connected") }
        guard let snapshot = metricsStore.snapshot(for: streamID),
              let encodedWidth = snapshot.hostEncodedWidth,
              let encodedHeight = snapshot.hostEncodedHeight,
              encodedWidth > 0,
              encodedHeight > 0 else {
            MirageLogger.client(
                "Ignoring automatic desktop workload reconfiguration for stream \(streamID): " +
                    "\(target.logLabel); missing encoded-size metrics"
            )
            return false
        }

        let currentPixels = max(1, Double(encodedWidth) * Double(encodedHeight))
        let targetPixels = max(1, target.encodedPixelCount)
        let scaleRatio = sqrt(targetPixels / currentPixels)
        let requestedScale = max(
            0.5,
            MirageStreamGeometry.clampStreamScale((runtimeWorkloadSafetyScaleByStream[streamID] ?? resolutionScale) * scaleRatio)
        )
        let currentFrameRate = runtimeWorkloadSafetyCurrentFrameRate(for: streamID)
        let requestedFrameRate = Self.runtimeWorkloadSafetyCappedFrameRate(
            target.targetFrameRate,
            cap: runtimeWorkloadSafetyFrameRateCap(for: streamID)
        )
        guard requestedScale < (runtimeWorkloadSafetyScaleByStream[streamID] ?? resolutionScale) ||
            requestedFrameRate < currentFrameRate else {
            MirageLogger.client(
                "Ignoring automatic desktop workload reconfiguration for stream \(streamID): " +
                    "\(target.logLabel); no lower workload than current scale/frame-rate"
            )
            return false
        }

        MirageLogger.client(
            "Requesting automatic desktop workload reconfiguration for stream \(streamID): " +
                "\(target.logLabel), scale=\(String(format: "%.2f", requestedScale)), " +
                "frameRate=\(requestedFrameRate)fps"
        )
        try await sendStreamEncoderSettingsChange(
            streamID: streamID,
            streamScale: requestedScale,
            targetFrameRate: requestedFrameRate
        )
        runtimeWorkloadSafetyScaleByStream[streamID] = requestedScale
        return true
    }
}
