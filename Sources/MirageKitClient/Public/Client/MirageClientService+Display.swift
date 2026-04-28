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
    /// Maximum encoded size Vision Pro clients should request from the host.
    public nonisolated static let visionOSMaximumEncodedPixelSize = CGSize(width: 3840, height: 2160)

    /// Vision Pro desktop streams should request a Retina-style virtual display
    /// even when UIKit has not yet reported a native window scale.
    public nonisolated static let visionOSPreferredVirtualDisplayScaleFactor: CGFloat = 2.0

    /// Total pixel count equivalent to 4K (3840 x 2160).
    private nonisolated static let fixedVisionOSPixelCount: CGFloat = 8_294_400

    /// Compute a display resolution that maintains a fixed 4K pixel budget
    /// while adapting the aspect ratio to the given view size and staying within
    /// the Vision Pro 4K encoded-size limit.
    /// Used on visionOS where resizing the window changes the aspect ratio
    /// rather than the resolution.
    public func visionOSFixedPixelCountResolution(for viewSize: CGSize) -> CGSize {
        Self.fixedPixelBudgetLogicalResolution(
            for: viewSize,
            displayScaleFactor: max(
                Self.visionOSPreferredVirtualDisplayScaleFactor,
                platformDisplayScaleFactor(explicitScaleFactor: nil)
            )
        )
    }

    nonisolated static func fixedPixelBudgetLogicalResolution(
        for viewSize: CGSize,
        displayScaleFactor: CGFloat,
        pixelCount: CGFloat = fixedVisionOSPixelCount,
        maximumEncodedPixelSize: CGSize = visionOSMaximumEncodedPixelSize
    )
    -> CGSize {
        let displayScaleFactor = max(
            visionOSPreferredVirtualDisplayScaleFactor,
            MirageStreamGeometry.clampedDisplayScaleFactor(displayScaleFactor)
        )
        let fallbackPixelSize = CGSize(
            width: max(2, maximumEncodedPixelSize.width),
            height: max(2, maximumEncodedPixelSize.height)
        )
        guard viewSize.width > 0, viewSize.height > 0 else {
            return MirageStreamGeometry.normalizedLogicalSize(
                CGSize(
                    width: fallbackPixelSize.width / displayScaleFactor,
                    height: fallbackPixelSize.height / displayScaleFactor
                )
            )
        }
        let aspectRatio = viewSize.width / viewSize.height
        let budgetHeight = sqrt(max(1, pixelCount) / aspectRatio)
        let budgetWidth = budgetHeight * aspectRatio
        let widthScale = maximumEncodedPixelSize.width > 0
            ? maximumEncodedPixelSize.width / budgetWidth
            : 1.0
        let heightScale = maximumEncodedPixelSize.height > 0
            ? maximumEncodedPixelSize.height / budgetHeight
            : 1.0
        let encodedScale = min(1.0, widthScale, heightScale)
        return MirageStreamGeometry.normalizedLogicalSize(
            CGSize(
                width: (budgetWidth * encodedScale) / displayScaleFactor,
                height: (budgetHeight * encodedScale) / displayScaleFactor
            )
        )
    }

    /// Get the display resolution for the client stream.
    func scaledDisplayResolution(_ resolution: CGSize) -> CGSize {
        MirageStreamGeometry.normalizedLogicalSize(resolution)
    }

    func clampedStreamScale() -> CGFloat {
        let scale = resolutionScale > 0 ? resolutionScale : 1.0
        return clampStreamScale(scale)
    }

    func clampStreamScale(_ scale: CGFloat) -> CGFloat {
        MirageStreamGeometry.clampStreamScale(scale)
    }

    public func virtualDisplayPixelResolution(for displayResolution: CGSize) -> CGSize {
        let alignedResolution = scaledDisplayResolution(displayResolution)
        guard alignedResolution.width > 0, alignedResolution.height > 0 else { return .zero }

        let requestedScale: CGFloat
        #if os(macOS)
        requestedScale = NSScreen.main?.backingScaleFactor ?? 2.0
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
            requestedScale = max(widthScale, heightScale)
        } else if metrics.nativeScale > 0 {
            requestedScale = metrics.nativeScale
        } else {
            requestedScale = 1.0
        }
        #else
        requestedScale = 1.0
        #endif

        return MirageStreamGeometry.resolve(
            logicalSize: alignedResolution,
            displayScaleFactor: requestedScale
        ).displayPixelSize
    }

    func resolvedDisplayScaleFactor(
        for logicalResolution: CGSize,
        explicitScaleFactor: CGFloat?
    )
    -> CGFloat? {
        let alignedLogical = scaledDisplayResolution(logicalResolution)
        guard alignedLogical.width > 0, alignedLogical.height > 0 else { return nil }
        let geometry = MirageStreamGeometry.resolve(
            logicalSize: alignedLogical,
            displayScaleFactor: platformDisplayScaleFactor(explicitScaleFactor: explicitScaleFactor)
        )
        guard geometry.displayScaleFactor > 0 else { return nil }
        return geometry.displayScaleFactor
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
        return scaledDisplayResolution(mainScreen.frame.size)
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
        guard let mainScreen = NSScreen.main else { return CGSize(width: 2560, height: 1600) }
        let scale = mainScreen.backingScaleFactor
        return scaledDisplayResolution(
            CGSize(
                width: mainScreen.frame.width * scale,
                height: mainScreen.frame.height * scale
            )
        )
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
        let displayResolution = getMainDisplayResolution()
        return virtualDisplayPixelResolution(for: displayResolution)
    }

    func resolvedStreamGeometry(
        for logicalResolution: CGSize,
        explicitScaleFactor: CGFloat? = nil,
        requestedStreamScale: CGFloat? = nil,
        encoderMaxWidth: Int? = nil,
        encoderMaxHeight: Int? = nil,
        disableResolutionCap: Bool = false
    ) -> MirageStreamGeometry {
        let alignedLogicalResolution = scaledDisplayResolution(logicalResolution)

        return MirageStreamGeometry.resolve(
            logicalSize: alignedLogicalResolution,
            displayScaleFactor: platformDisplayScaleFactor(explicitScaleFactor: explicitScaleFactor),
            requestedStreamScale: requestedStreamScale ?? clampedStreamScale(),
            encoderMaxWidth: encoderMaxWidth,
            encoderMaxHeight: encoderMaxHeight,
            disableResolutionCap: disableResolutionCap
        )
    }

    private func platformDisplayScaleFactor(explicitScaleFactor: CGFloat?) -> CGFloat {
        if let explicitScaleFactor, explicitScaleFactor > 0 {
            return max(1.0, explicitScaleFactor)
        }

        #if os(macOS)
        return NSScreen.main?.backingScaleFactor ?? 2.0
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
            return max(1.0, max(widthScale, heightScale))
        }
        if metrics.nativeScale > 0 { return max(1.0, metrics.nativeScale) }
        return 1.0
        #else
        return 1.0
        #endif
    }

    /// Get the selected target refresh rate requested by the client.
    public func getScreenMaxRefreshRate() -> Int {
        Self.resolvedRequestedRefreshRate(
            override: maxRefreshRateOverride,
            preferredMaximumRefreshRate: MirageRenderPreferences.preferredMaximumRefreshRate()
        )
    }

    nonisolated static func resolvedRequestedRefreshRate(
        override: Int?,
        preferredMaximumRefreshRate: Int
    ) -> Int {
        if let override {
            return MirageRenderModePolicy.normalizedTargetFPS(override)
        }
        return MirageRenderModePolicy.normalizedTargetFPS(preferredMaximumRefreshRate)
    }

    public func updateMaxRefreshRateOverride(_ newValue: Int) {
        let clamped = MirageRenderModePolicy.normalizedTargetFPS(newValue)
        guard maxRefreshRateOverride != clamped else { return }
        maxRefreshRateOverride = clamped
    }

    /// Send display size change (points) to host when the client view bounds change.
    public func sendDisplayResolutionChange(streamID: StreamID, newResolution: CGSize) async throws {
        guard case .connected = connectionState else { throw MirageError.protocolError("Not connected") }

        let scaledResolution = scaledDisplayResolution(newResolution)

        let pixelResolution = virtualDisplayPixelResolution(for: scaledResolution)
        let request = DisplayResolutionChangeMessage(
            streamID: streamID,
            displayWidth: Int(scaledResolution.width),
            displayHeight: Int(scaledResolution.height)
        )
        MirageLogger
            .client(
                "Sending display size change for stream \(streamID): " +
                    "\(Int(scaledResolution.width))x\(Int(scaledResolution.height)) pts " +
                    "(\(Int(pixelResolution.width))x\(Int(pixelResolution.height)) px)"
            )

        try await sendControlMessage(.displayResolutionChange, content: request)
    }

    @discardableResult
    public func requestAutomaticDesktopWorkloadReconfiguration(
        streamID: StreamID,
        target: MirageAutomaticDesktopWorkloadTier
    )
    async throws -> Bool {
        guard case .connected = connectionState else { throw MirageError.protocolError("Not connected") }
        guard desktopStreamID == streamID else { return false }
        guard pendingLocalDesktopStopStreamID != streamID else { return false }
        guard !startupCriticalSectionActive, !hasActivePostResizeTransition else { return false }
        guard let session = sessionStore.sessionByStreamID(streamID),
              session.hasPresentedFrame,
              session.clientRecoveryStatus == .idle else {
            return false
        }

        let snapshot = metricsStore.snapshot(for: streamID)
        let currentFrameRate = snapshot?.hostTargetFrameRate ?? 0
        let needsFrameRateChange = currentFrameRate > 0 && currentFrameRate != target.targetFrameRate
        let currentEncodedSize = CGSize(
            width: snapshot?.hostEncodedWidth ?? 0,
            height: snapshot?.hostEncodedHeight ?? 0
        )
        let needsResize = !Self.approximatelyEqualEncodedSize(
            currentEncodedSize,
            target.encodedPixelSize
        )

        guard needsFrameRateChange || needsResize else { return false }

        if needsFrameRateChange {
            try await sendStreamEncoderSettingsChange(
                streamID: streamID,
                targetFrameRate: target.targetFrameRate
            )
        }

        if needsResize {
            let logicalResolution = automaticDesktopLogicalResolution(
                forEncodedPixelSize: target.encodedPixelSize
            )
            let resizeTarget = desktopResizeTarget(
                for: logicalResolution,
                maxDrawableSize: target.encodedPixelSize
            )
            queueDesktopResize(
                streamID: streamID,
                target: resizeTarget,
                hasPresentedFrame: session.hasPresentedFrame,
                useHostResolution: false
            )
        }

        MirageLogger.client(
            "Requested automatic desktop workload reconfiguration for stream \(streamID): \(target.logLabel)"
        )
        return true
    }

    private func automaticDesktopLogicalResolution(forEncodedPixelSize encodedPixelSize: CGSize) -> CGSize {
        let displayScaleFactor = platformDisplayScaleFactor(explicitScaleFactor: nil)
        return MirageStreamGeometry.normalizedLogicalSize(
            CGSize(
                width: encodedPixelSize.width / displayScaleFactor,
                height: encodedPixelSize.height / displayScaleFactor
            )
        )
    }

    private nonisolated static func approximatelyEqualEncodedSize(_ lhs: CGSize, _ rhs: CGSize) -> Bool {
        guard lhs.width > 0, lhs.height > 0, rhs.width > 0, rhs.height > 0 else { return false }
        return abs(lhs.width - rhs.width) <= 16 && abs(lhs.height - rhs.height) <= 16
    }

    func sendDesktopResizeRequest(
        streamID: StreamID,
        newResolution: CGSize,
        transitionID: UUID,
        requestedDisplayScaleFactor: CGFloat,
        requestedStreamScale: CGFloat,
        encoderMaxWidth: Int?,
        encoderMaxHeight: Int?
    )
    async throws {
        guard case .connected = connectionState else { throw MirageError.protocolError("Not connected") }

        let scaledResolution = scaledDisplayResolution(newResolution)
        let clampedDisplayScaleFactor = max(1.0, requestedDisplayScaleFactor)
        let clampedStreamScale = clampStreamScale(requestedStreamScale)
        let pixelResolution = MirageStreamGeometry.resolve(
            logicalSize: scaledResolution,
            displayScaleFactor: clampedDisplayScaleFactor
        ).displayPixelSize

        let request = DisplayResolutionChangeMessage(
            streamID: streamID,
            displayWidth: Int(scaledResolution.width),
            displayHeight: Int(scaledResolution.height),
            transitionID: transitionID,
            requestedDisplayScaleFactor: clampedDisplayScaleFactor,
            requestedStreamScale: clampedStreamScale,
            encoderMaxWidth: encoderMaxWidth,
            encoderMaxHeight: encoderMaxHeight
        )
        MirageLogger.client(
            "Sending desktop resize request for stream \(streamID): " +
                "\(Int(scaledResolution.width))x\(Int(scaledResolution.height)) pts " +
                "(\(Int(pixelResolution.width))x\(Int(pixelResolution.height)) px), " +
                "transition=\(transitionID.uuidString), " +
                "displayScale=\(String(format: "%.3f", clampedDisplayScaleFactor)), " +
                "streamScale=\(String(format: "%.3f", clampedStreamScale))"
        )
        try await sendControlMessage(.displayResolutionChange, content: request)
    }

    public func sendStreamScaleChange(
        streamID: StreamID,
        scale: CGFloat
    )
    async throws {
        guard case .connected = connectionState else { throw MirageError.protocolError("Not connected") }

        let clampedScale = clampStreamScale(scale)
        let request = StreamScaleChangeMessage(
            streamID: streamID,
            streamScale: clampedScale
        )
        MirageLogger.client("Sending stream scale change for stream \(streamID): \(clampedScale)")
        try await sendControlMessage(.streamScaleChange, content: request)
    }

    func sendStreamRefreshRateChange(
        streamID: StreamID,
        maxRefreshRate: Int,
        forceDisplayRefresh: Bool = false
    )
    async throws {
        guard case .connected = connectionState else { throw MirageError.protocolError("Not connected") }

        let clamped = MirageRenderModePolicy.normalizedTargetFPS(maxRefreshRate)
        let request = StreamRefreshRateChangeMessage(
            streamID: streamID,
            maxRefreshRate: clamped,
            forceDisplayRefresh: forceDisplayRefresh ? true : nil
        )
        MirageLogger.client("Sending refresh rate override for stream \(streamID): \(clamped)Hz")
        try await sendControlMessage(.streamRefreshRateChange, content: request)
    }

    func updateStreamRefreshRateOverride(streamID: StreamID, maxRefreshRate: Int) {
        let clamped = MirageRenderModePolicy.normalizedTargetFPS(maxRefreshRate)
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

    #if os(iOS) || os(visionOS)
    public static func clearCachedDisplayMetrics() {
        lastKnownViewSize = .zero
        lastKnownDrawablePixelSize = .zero
        lastKnownScreenPointSize = .zero
        lastKnownScreenScale = 0
        lastKnownScreenNativePixelSize = .zero
        lastKnownScreenNativeScale = 0
    }

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
