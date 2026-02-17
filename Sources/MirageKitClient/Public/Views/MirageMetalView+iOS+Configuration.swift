//
//  MirageMetalView+iOS+Configuration.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/17/26.
//
//  Layout, preference, and color-format helpers for MirageMetalView.
//

import MirageKit
#if os(iOS) || os(visionOS)
import CoreVideo
import Metal
import QuartzCore
import UIKit

extension MirageMetalView {
    // MARK: - Metrics / Layout

    func reportDrawableMetricsIfChanged() {
        let drawableSize = metalLayer.drawableSize
        guard drawableSize.width > 0, drawableSize.height > 0 else { return }
        guard drawableSize != lastReportedDrawableSize else { return }

        lastReportedDrawableSize = drawableSize
        let metrics = currentDrawableMetrics(drawableSize: drawableSize)
        let callback = onDrawableMetricsChanged
        Task { @MainActor in
            callback?(metrics)
        }
    }

    #if os(visionOS)
    private func currentDrawableMetrics(drawableSize: CGSize) -> MirageDrawableMetrics {
        let boundsSize = bounds.size
        let scaleX = boundsSize.width > 0 ? drawableSize.width / boundsSize.width : 0
        let scaleY = boundsSize.height > 0 ? drawableSize.height / boundsSize.height : 0
        let scale = max(0.1, max(scaleX, scaleY))
        let windowPointSize = window?.bounds.size ?? boundsSize
        let screenScale = traitCollection.displayScale > 0 ? traitCollection.displayScale : 1
        let nativePixelSize = CGSize(
            width: windowPointSize.width * screenScale,
            height: windowPointSize.height * screenScale
        )

        return MirageDrawableMetrics(
            pixelSize: drawableSize,
            viewSize: boundsSize,
            scaleFactor: scale,
            screenPointSize: windowPointSize,
            screenScale: screenScale,
            screenNativePixelSize: nativePixelSize,
            screenNativeScale: screenScale
        )
    }
    #else
    private func currentDrawableMetrics(drawableSize: CGSize) -> MirageDrawableMetrics {
        let boundsSize = bounds.size
        let scaleX = boundsSize.width > 0 ? drawableSize.width / boundsSize.width : 0
        let scaleY = boundsSize.height > 0 ? drawableSize.height / boundsSize.height : 0
        let scale = max(0.1, max(scaleX, scaleY))
        let screen = resolveCurrentScreen()
        let nativeScale = screen.nativeScale > 0 ? screen.nativeScale : screen.scale

        return MirageDrawableMetrics(
            pixelSize: drawableSize,
            viewSize: boundsSize,
            scaleFactor: scale,
            screenPointSize: screen.bounds.size,
            screenScale: screen.scale,
            screenNativePixelSize: orientedNativePixelSize(for: screen),
            screenNativeScale: nativeScale
        )
    }

    private func resolveCurrentScreen() -> UIScreen {
        if let screen = window?.windowScene?.screen { return screen }
        if let screen = window?.screen { return screen }
        return UIScreen.main
    }

    private func orientedNativePixelSize(for screen: UIScreen) -> CGSize {
        let nativeSize = screen.nativeBounds.size
        let pointSize = screen.bounds.size
        guard nativeSize.width > 0, nativeSize.height > 0 else { return .zero }

        let nativeIsLandscape = nativeSize.width >= nativeSize.height
        let pointsAreLandscape = pointSize.width >= pointSize.height
        if nativeIsLandscape == pointsAreLandscape { return nativeSize }

        return CGSize(width: nativeSize.height, height: nativeSize.width)
    }
    #endif

    func cappedDrawableSize(_ size: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return size }

        if let maxDrawableSize, maxDrawableSize.width <= 0 || maxDrawableSize.height <= 0 {
            return CGSize(width: alignedEven(size.width), height: alignedEven(size.height))
        }

        var width = size.width
        var height = size.height
        let aspectRatio = width / height
        let maxSize = resolvedMaxDrawableSize()

        if width > maxSize.width {
            width = maxSize.width
            height = width / aspectRatio
        }

        if height > maxSize.height {
            height = maxSize.height
            width = height * aspectRatio
        }

        return CGSize(width: alignedEven(width), height: alignedEven(height))
    }

    private func resolvedMaxDrawableSize() -> CGSize {
        let defaultSize = CGSize(width: Self.maxDrawableWidth, height: Self.maxDrawableHeight)
        guard let maxDrawableSize,
              maxDrawableSize.width > 0,
              maxDrawableSize.height > 0 else {
            return defaultSize
        }

        return CGSize(
            width: min(defaultSize.width, maxDrawableSize.width),
            height: min(defaultSize.height, maxDrawableSize.height)
        )
    }

    private func alignedEven(_ value: CGFloat) -> CGFloat {
        let rounded = CGFloat(Int(value.rounded()))
        let even = rounded - CGFloat(Int(rounded) % 2)
        return max(2, even)
    }

    // MARK: - Preferences

    func applyRenderPreferences() {
        let proMotionEnabled = MirageRenderPreferences.proMotionEnabled()
        refreshRateMonitor.isProMotionEnabled = proMotionEnabled
        renderLoop.updateAllowDegradationRecovery(MirageRenderPreferences.allowAdaptiveFallback())
        updateFrameRatePreference(proMotionEnabled: proMotionEnabled)
        requestDraw()
    }

    private func updateFrameRatePreference(proMotionEnabled: Bool) {
        let desired = proMotionEnabled ? 120 : 60
        applyRefreshRateOverride(desired)
    }

    func applyRefreshRateOverride(_ override: Int) {
        let clamped = override >= 120 ? 120 : 60
        maxRenderFPS = clamped
        renderLoop.updateTargetFPS(clamped)
        applyDisplayRefreshRateLock(clamped)
        onRefreshRateOverrideChange?(clamped)
    }

    func applyDisplayRefreshRateLock(_ fps: Int) {
        let clamped = fps >= 120 ? 120 : 60
        let changed = appliedRefreshRateLock != clamped
        appliedRefreshRateLock = clamped
        metalLayer.maximumDrawableCount = desiredMaxInFlightDraws()

        guard changed else { return }
        MirageLogger.renderer("Applied iOS render refresh lock: \(clamped)Hz")
    }

    func startObservingPreferences() {
        preferencesObserver.start { [weak self] in
            self?.applyRenderPreferences()
        }
    }

    func stopObservingPreferences() {
        preferencesObserver.stop()
    }

    // MARK: - Color Output

    func updateOutputFormatIfNeeded(_ pixelFormatType: OSType) {
        let outputPixelFormat: MTLPixelFormat
        let colorSpace: CGColorSpace?
        let wantsHDR: Bool

        switch pixelFormatType {
        case kCVPixelFormatType_32BGRA,
             kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
             kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            outputPixelFormat = .bgra8Unorm
            colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
            wantsHDR = false
        case kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
             kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange:
            outputPixelFormat = .bgr10a2Unorm
            colorSpace = CGColorSpace(name: CGColorSpace.displayP3)
            wantsHDR = true
        default:
            outputPixelFormat = .bgr10a2Unorm
            colorSpace = CGColorSpace(name: CGColorSpace.displayP3)
            wantsHDR = true
        }

        guard colorPixelFormat != outputPixelFormat else { return }
        colorPixelFormat = outputPixelFormat

        let metalLayer = self.metalLayer
        metalLayer.pixelFormat = outputPixelFormat
        metalLayer.colorspace = colorSpace
        metalLayer.wantsExtendedDynamicRangeContent = wantsHDR
    }
}
#endif
