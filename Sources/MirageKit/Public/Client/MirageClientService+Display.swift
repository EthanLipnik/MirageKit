//
//  MirageClientService+Display.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Display resolution helpers and host notifications.
//

import CoreGraphics
import Foundation

#if canImport(AppKit)
import AppKit
#endif

#if canImport(UIKit)
import UIKit
#endif

@MainActor
extension MirageClientService {
    /// Get the display resolution for the client stream.
    func scaledDisplayResolution(_ resolution: CGSize) -> CGSize {
        let width = max(2, floor(resolution.width / 2) * 2)
        let height = max(2, floor(resolution.height / 2) * 2)
        return CGSize(width: width, height: height)
    }

    func clampedStreamScale() -> CGFloat {
        let scale = resolutionScale
        guard scale > 0 else { return 1.0 }
        return max(0.1, min(1.0, scale))
    }

    func getMainDisplayResolution() -> CGSize {
        #if os(macOS)
        guard let mainScreen = NSScreen.main else { return CGSize(width: 2560, height: 1600) }
        let scale = mainScreen.backingScaleFactor
        return CGSize(
            width: mainScreen.frame.width * scale,
            height: mainScreen.frame.height * scale
        )
        #elseif os(iOS)
        if Self.lastKnownDrawableSize.width > 0, Self.lastKnownDrawableSize.height > 0 { return Self.lastKnownDrawableSize }
        let screen = UIScreen.main
        let nativeBounds = screen.nativeBounds
        if nativeBounds.width > 0, nativeBounds.height > 0 { return nativeBounds.size }
        let scale = screen.nativeScale
        return CGSize(
            width: screen.bounds.width * scale,
            height: screen.bounds.height * scale
        )
        #elseif os(visionOS)
        // Use cached drawable size if available, otherwise default resolution
        if Self.lastKnownDrawableSize.width > 0, Self.lastKnownDrawableSize.height > 0 { return Self.lastKnownDrawableSize }
        return CGSize(width: 2560, height: 1600)
        #else
        return CGSize(width: 2560, height: 1600)
        #endif
    }

    /// Get the maximum refresh rate requested by the client.
    func getScreenMaxRefreshRate() -> Int {
        #if os(iOS)
        let knownMax = MirageClientService.lastKnownScreenMaxFPS
        let screenMax = knownMax > 0 ? knownMax : 60
        if let override = maxRefreshRateOverride { return min(override, screenMax) }
        return screenMax
        #else
        let screenMax: Int
        #if os(macOS)
        screenMax = NSScreen.main?.maximumFramesPerSecond ?? 120
        #elseif os(visionOS)
        screenMax = 120
        #else
        screenMax = 60
        #endif

        if let override = maxRefreshRateOverride { return override }
        return screenMax
        #endif
    }

    public func updateMaxRefreshRateOverride(_ newValue: Int) {
        let clamped = clampRefreshRate(newValue)
        guard maxRefreshRateOverride != clamped else { return }
        maxRefreshRateOverride = clamped
    }

    /// Send display resolution change to host (when window moves to different display).
    public func sendDisplayResolutionChange(streamID: StreamID, newResolution: CGSize) async throws {
        guard case .connected = connectionState, let connection else { throw MirageError.protocolError("Not connected") }

        let scaledResolution = scaledDisplayResolution(newResolution)
        let request = DisplayResolutionChangeMessage(
            streamID: streamID,
            displayWidth: Int(scaledResolution.width),
            displayHeight: Int(scaledResolution.height)
        )
        let message = try ControlMessage(type: .displayResolutionChange, content: request)

        MirageLogger
            .client(
                "Sending display resolution change for stream \(streamID): \(Int(scaledResolution.width))x\(Int(scaledResolution.height))"
            )

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: message.serialize(), completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else {
                    continuation.resume()
                }
            })
        }
    }

    public func sendStreamScaleChange(
        streamID: StreamID,
        scale: CGFloat
    )
    async throws {
        guard case .connected = connectionState, let connection else { throw MirageError.protocolError("Not connected") }

        let clampedScale = max(0.1, min(1.0, scale))
        let request = StreamScaleChangeMessage(
            streamID: streamID,
            streamScale: clampedScale
        )
        let message = try ControlMessage(type: .streamScaleChange, content: request)

        let roundedScale = (clampedScale * 100).rounded() / 100
        MirageLogger.client("Sending stream scale change for stream \(streamID): \(roundedScale)")

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: message.serialize(), completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else {
                    continuation.resume()
                }
            })
        }
    }

    func sendStreamRefreshRateChange(
        streamID: StreamID,
        maxRefreshRate: Int,
        forceDisplayRefresh: Bool = false
    )
    async throws {
        guard case .connected = connectionState, let connection else { throw MirageError.protocolError("Not connected") }

        let clamped = clampRefreshRate(maxRefreshRate)
        let request = StreamRefreshRateChangeMessage(
            streamID: streamID,
            maxRefreshRate: clamped,
            forceDisplayRefresh: forceDisplayRefresh ? true : nil
        )
        let message = try ControlMessage(type: .streamRefreshRateChange, content: request)

        MirageLogger.client("Sending refresh rate override for stream \(streamID): \(clamped)Hz")

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: message.serialize(), completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else {
                    continuation.resume()
                }
            })
        }
    }

    func updateStreamRefreshRateOverride(streamID: StreamID, maxRefreshRate: Int) {
        let clamped = clampRefreshRate(maxRefreshRate)
        let existing = refreshRateOverridesByStream[streamID]
        guard existing != clamped else { return }
        refreshRateOverridesByStream[streamID] = clamped
        refreshRateMismatchCounts.removeValue(forKey: streamID)
        refreshRateFallbackTargets.removeValue(forKey: streamID)

        Task { [weak self] in
            try? await self?.sendStreamRefreshRateChange(streamID: streamID, maxRefreshRate: clamped)
        }
    }

    func clearStreamRefreshRateOverride(streamID: StreamID) {
        refreshRateOverridesByStream.removeValue(forKey: streamID)
        refreshRateMismatchCounts.removeValue(forKey: streamID)
        refreshRateFallbackTargets.removeValue(forKey: streamID)
    }

    private func clampRefreshRate(_ rate: Int) -> Int {
        guard rate > 0 else { return 60 }
        return rate >= 120 ? 120 : 60
    }
}
