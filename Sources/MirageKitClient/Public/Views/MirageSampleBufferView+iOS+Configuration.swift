//
//  MirageSampleBufferView+iOS+Configuration.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/17/26.
//
//  Layout and refresh-rate helpers for MirageSampleBufferView.
//

import MirageKit
#if os(iOS) || os(visionOS)
import UIKit

extension MirageSampleBufferView {
    // MARK: - Configuration

    func applyRenderConfiguration() {
        presentationPipeline.applyConfiguration(
            MirageStreamRenderConfiguration(
                logicalStreamID: streamID,
                mediaStreamID: streamID,
                contentRectOverride: contentRectOverride,
                presentationTier: streamPresentationTier,
                preferredMaximumRenderFPS: preferredMaximumRenderFPS,
                maxDrawableSize: maxDrawableSize,
                prefersLocalAspectFitPresentation: prefersLocalAspectFitPresentation,
                containerSizingMode: .viewBounds
            )
        )
    }

    // MARK: - Metrics / Layout

    func currentDrawableMetricsContext() -> MirageDrawableMetricsContext {
        #if os(visionOS)
        let boundsSize = bounds.size
        let windowPointSize = window?.bounds.size ?? boundsSize
        let screenScale = traitCollection.displayScale > 0 ? traitCollection.displayScale : 1
        let nativePixelSize = CGSize(
            width: windowPointSize.width * screenScale,
            height: windowPointSize.height * screenScale
        )

        return MirageDrawableMetricsContext(
            screenPointSize: windowPointSize,
            screenScale: screenScale,
            screenNativePixelSize: nativePixelSize,
            screenNativeScale: screenScale
        )
        #else
        let screen = resolveCurrentScreen()
        let nativeScale = screen.nativeScale > 0 ? screen.nativeScale : screen.scale

        return MirageDrawableMetricsContext(
            screenPointSize: screen.bounds.size,
            screenScale: screen.scale,
            screenNativePixelSize: orientedNativePixelSize(for: screen),
            screenNativeScale: nativeScale
        )
        #endif
    }

    #if !os(visionOS)
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

    // MARK: - Preferences

    func applyRenderPreferences() {
        refreshRateMonitor.preferredMaximumRefreshRate =
            preferredMaximumRenderFPS ?? MirageRenderPreferences.preferredMaximumRefreshRate()
        requestImmediateSubmission()
    }

    func applyRefreshRateOverride(_ override: Int) {
        presentationPipeline.applyResolvedRenderFPS(override)
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
