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
import MirageKit

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
        guard resolution.width > 0, resolution.height > 0 else { return .zero }
        let width = max(2, floor(resolution.width / 2) * 2)
        let height = max(2, floor(resolution.height / 2) * 2)
        return CGSize(width: width, height: height)
    }

    func clampedStreamScale() -> CGFloat {
        let scale = resolutionScale
        guard scale > 0 else { return 1.0 }
        return clampStreamScale(scale)
    }

    func clampStreamScale(_ scale: CGFloat) -> CGFloat {
        guard scale > 0 else { return 1.0 }
        return max(0.1, min(1.0, scale))
    }

    func virtualDisplayPixelResolution(for displayResolution: CGSize) -> CGSize {
        let alignedResolution = scaledDisplayResolution(displayResolution)
        guard alignedResolution.width > 0, alignedResolution.height > 0 else { return .zero }

        #if os(macOS)
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        let pixelSize = CGSize(
            width: alignedResolution.width * scale,
            height: alignedResolution.height * scale
        )
        return scaledDisplayResolution(pixelSize)
        #elseif os(iOS) || os(visionOS)
        let metrics = resolvedScreenMetrics()
        let nativePoints = scaledDisplayResolution(metrics.nativePointSize)
        let nativePixels = scaledDisplayResolution(metrics.nativePixelSize)
        if nativePoints.width > 0,
           nativePoints.height > 0,
           nativePixels.width > 0,
           nativePixels.height > 0 {
            let widthScale = nativePixels.width / nativePoints.width
            let heightScale = nativePixels.height / nativePoints.height
            let pixelSize = CGSize(
                width: alignedResolution.width * widthScale,
                height: alignedResolution.height * heightScale
            )
            return scaledDisplayResolution(pixelSize)
        }

        if metrics.nativeScale > 0 {
            let pixelSize = CGSize(
                width: alignedResolution.width * metrics.nativeScale,
                height: alignedResolution.height * metrics.nativeScale
            )
            return scaledDisplayResolution(pixelSize)
        }
        return alignedResolution
        #else
        return alignedResolution
        #endif
    }

    func preferredDesktopDisplayResolution(for viewSize: CGSize) -> CGSize {
        let alignedViewSize = scaledDisplayResolution(viewSize)
        guard alignedViewSize.width > 0, alignedViewSize.height > 0 else { return .zero }

        #if os(iOS) || os(visionOS)
        let metrics = resolvedScreenMetrics()
        let screenPoints = scaledDisplayResolution(metrics.pointSize)
        let nativePoints = scaledDisplayResolution(metrics.nativePointSize)
        if screenPoints.width > 0,
           screenPoints.height > 0,
           nativePoints.width > 0,
           nativePoints.height > 0,
           approximatelyEqualSizes(alignedViewSize, screenPoints) {
            return nativePoints
        }
        #endif

        return alignedViewSize
    }

    public func getMainDisplayResolution() -> CGSize {
        #if os(macOS)
        guard let mainScreen = NSScreen.main else { return CGSize(width: 2560, height: 1600) }
        let scale = mainScreen.backingScaleFactor
        return CGSize(
            width: mainScreen.frame.width * scale,
            height: mainScreen.frame.height * scale
        )
        #elseif os(iOS) || os(visionOS)
        let metrics = resolvedScreenMetrics()
        let nativePoints = scaledDisplayResolution(metrics.nativePointSize)
        if nativePoints.width > 0, nativePoints.height > 0 { return nativePoints }
        if Self.lastKnownViewSize.width > 0, Self.lastKnownViewSize.height > 0 {
            return scaledDisplayResolution(Self.lastKnownViewSize)
        }
        return .zero
        #else
        return CGSize(width: 2560, height: 1600)
        #endif
    }

    public func getMainDisplayNativePixelResolution() -> CGSize {
        #if os(macOS)
        return getMainDisplayResolution()
        #elseif os(iOS) || os(visionOS)
        let metrics = resolvedScreenMetrics()
        let nativePixels = scaledDisplayResolution(metrics.nativePixelSize)
        if nativePixels.width > 0, nativePixels.height > 0 { return nativePixels }

        let cachedNativePixels = scaledDisplayResolution(Self.lastKnownScreenNativePixelSize)
        if cachedNativePixels.width > 0, cachedNativePixels.height > 0 {
            return cachedNativePixels
        }
        return .zero
        #else
        return CGSize(width: 2560, height: 1600)
        #endif
    }

    public func getVirtualDisplayPixelResolution() -> CGSize {
        #if os(iOS) || os(visionOS)
        let displayResolution = getMainDisplayResolution()
        return virtualDisplayPixelResolution(for: displayResolution)
        #else
        return getMainDisplayResolution()
        #endif
    }

    /// Get the maximum refresh rate requested by the client.
    public func getScreenMaxRefreshRate() -> Int {
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

    /// Send display size change (points) to host when the client view bounds change.
    public func sendDisplayResolutionChange(streamID: StreamID, newResolution: CGSize) async throws {
        guard case .connected = connectionState, let connection else { throw MirageError.protocolError("Not connected") }

        let scaledResolution = scaledDisplayResolution(newResolution)
        let pixelResolution = virtualDisplayPixelResolution(for: scaledResolution)
        let request = DisplayResolutionChangeMessage(
            streamID: streamID,
            displayWidth: Int(scaledResolution.width),
            displayHeight: Int(scaledResolution.height)
        )
        let message = try ControlMessage(type: .displayResolutionChange, content: request)

        MirageLogger
            .client(
                "Sending display size change for stream \(streamID): " +
                    "\(Int(scaledResolution.width))x\(Int(scaledResolution.height)) pts " +
                    "(\(Int(pixelResolution.width))x\(Int(pixelResolution.height)) px)"
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

        let clampedScale = clampStreamScale(scale)
        let request = StreamScaleChangeMessage(
            streamID: streamID,
            streamScale: clampedScale
        )
        let message = try ControlMessage(type: .streamScaleChange, content: request)

        MirageLogger.client("Sending stream scale change for stream \(streamID): \(clampedScale)")

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

    #if os(iOS) || os(visionOS)
    private struct ScreenMetrics {
        let pointSize: CGSize
        let scale: CGFloat
        let nativePixelSize: CGSize
        let nativeScale: CGFloat

        var nativePointSize: CGSize {
            guard nativeScale > 0, nativePixelSize.width > 0, nativePixelSize.height > 0 else { return .zero }
            return CGSize(
                width: nativePixelSize.width / nativeScale,
                height: nativePixelSize.height / nativeScale
            )
        }
    }

    private func resolvedScreenMetrics() -> ScreenMetrics {
        if let cached = cachedScreenMetrics() { return cached }
        return liveScreenMetrics()
    }

    private func cachedScreenMetrics() -> ScreenMetrics? {
        let pointSize = Self.lastKnownScreenPointSize
        let scale = Self.lastKnownScreenScale
        let nativePixelSize = Self.lastKnownScreenNativePixelSize
        let nativeScale = Self.lastKnownScreenNativeScale

        guard pointSize.width > 0,
              pointSize.height > 0,
              nativePixelSize.width > 0,
              nativePixelSize.height > 0,
              nativeScale > 0 else {
            return nil
        }

        return ScreenMetrics(
            pointSize: pointSize,
            scale: max(1.0, scale),
            nativePixelSize: nativePixelSize,
            nativeScale: max(1.0, nativeScale)
        )
    }

    private func liveScreenMetrics() -> ScreenMetrics {
        #if os(iOS)
        if let screen = UIWindow.current?.windowScene?.screen ?? UIWindow.current?.screen {
            let pointSize = screen.bounds.size
            let nativePixelSize = orientedNativePixelSize(
                nativeSize: screen.nativeBounds.size,
                pointSize: pointSize
            )
            let scale = max(1.0, screen.scale)
            let nativeScale = max(1.0, screen.nativeScale)

            return ScreenMetrics(
                pointSize: pointSize,
                scale: scale,
                nativePixelSize: nativePixelSize,
                nativeScale: nativeScale
            )
        }
        #endif

        let pointSize = Self.lastKnownScreenPointSize.width > 0 ? Self.lastKnownScreenPointSize : Self.lastKnownViewSize
        let scale = max(1.0, Self.lastKnownScreenScale)
        let nativePixelSize = Self.lastKnownScreenNativePixelSize
        let nativeScale = max(1.0, Self.lastKnownScreenNativeScale)

        return ScreenMetrics(
            pointSize: pointSize,
            scale: scale,
            nativePixelSize: nativePixelSize,
            nativeScale: nativeScale
        )
    }

    private func orientedNativePixelSize(nativeSize: CGSize, pointSize: CGSize) -> CGSize {
        guard nativeSize.width > 0, nativeSize.height > 0 else { return .zero }
        let nativeIsLandscape = nativeSize.width >= nativeSize.height
        let pointsAreLandscape = pointSize.width >= pointSize.height
        if nativeIsLandscape == pointsAreLandscape { return nativeSize }
        return CGSize(width: nativeSize.height, height: nativeSize.width)
    }

    private func approximatelyEqualSizes(_ lhs: CGSize, _ rhs: CGSize) -> Bool {
        let widthTolerance = max(8, rhs.width * 0.02)
        let heightTolerance = max(8, rhs.height * 0.02)
        return abs(lhs.width - rhs.width) <= widthTolerance &&
            abs(lhs.height - rhs.height) <= heightTolerance
    }
    #endif
}
