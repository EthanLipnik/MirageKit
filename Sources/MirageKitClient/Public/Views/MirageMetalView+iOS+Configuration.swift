//
//  MirageMetalView+iOS+Configuration.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/17/26.
//
//  Layout and refresh-rate helpers for MirageMetalView.
//

import MirageKit
#if os(iOS) || os(visionOS)
import QuartzCore
import UIKit

extension MirageMetalView {
    // MARK: - Metrics / Layout

    func reportDrawableMetricsIfChanged() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let pixelSize = cappedDrawableSize(
            CGSize(
                width: bounds.width * contentScaleFactor,
                height: bounds.height * contentScaleFactor
            )
        )
        let drawableSize = pixelSize
        guard drawableSize.width > 0, drawableSize.height > 0 else { return }
        guard drawableSize != lastReportedDrawableSize else { return }

        lastReportedDrawableSize = drawableSize
        let metrics = currentDrawableMetrics(drawableSize: drawableSize)
        onDrawableMetricsChanged?(metrics)
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
        applyDisplayRefreshRateLock(clamped)
        onRefreshRateOverrideChange?(clamped)
    }

    func applyDisplayRefreshRateLock(_ fps: Int) {
        let clamped = fps >= 120 ? 120 : 60
        let changed = appliedRefreshRateLock != clamped
        appliedRefreshRateLock = clamped
        if let displayLink {
            configureDisplayLinkRate(displayLink, fps: clamped)
        }

        guard changed else { return }
        MirageLogger.renderer("Applied iOS render refresh lock: \(clamped)Hz")
    }

    func configureDisplayLinkRate(_ displayLink: CADisplayLink, fps: Int) {
        let clamped = fps >= 120 ? 120 : 60
        if #available(iOS 15.0, visionOS 1.0, *) {
            let preferred = Float(clamped)
            displayLink.preferredFrameRateRange = CAFrameRateRange(
                minimum: preferred,
                maximum: preferred,
                preferred: preferred
            )
        } else {
            displayLink.preferredFramesPerSecond = clamped
        }
    }

    func startObservingPreferences() {
        preferencesObserver.start { [weak self] in
            self?.applyRenderPreferences()
        }
    }

    func stopObservingPreferences() {
        preferencesObserver.stop()
    }
}
#endif
