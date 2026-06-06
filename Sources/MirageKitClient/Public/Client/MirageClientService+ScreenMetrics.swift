//
//  MirageClientService+ScreenMetrics.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/12/26.
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
import CoreGraphics
import Foundation

#if canImport(UIKit)
import UIKit
#endif

#if os(iOS) || os(visionOS)

@MainActor
extension MirageClientService {
    /// Screen metrics captured from UIKit or the latest stream view update.
    struct ScreenMetrics {
        let pointSize: CGSize
        let scale: CGFloat
        let nativePixelSize: CGSize
        let nativeScale: CGFloat

        /// Native screen size in logical points.
        var nativePointSize: CGSize {
            guard nativeScale > 0, nativePixelSize.width > 0, nativePixelSize.height > 0 else { return .zero }
            return CGSize(
                width: nativePixelSize.width / nativeScale,
                height: nativePixelSize.height / nativeScale
            )
        }
    }

    /// Clears cached iOS and visionOS display metrics captured from stream views.
    public static func clearCachedDisplayMetrics() {
        lastKnownViewSize = .zero
        lastKnownDrawablePixelSize = .zero
        lastKnownScreenPointSize = .zero
        lastKnownScreenScale = 0
        lastKnownScreenNativePixelSize = .zero
        lastKnownScreenNativeScale = 0
    }

    /// Best available screen metrics, preferring the last captured scene metrics before reading
    /// directly from the active UIKit screen.
    var resolvedScreenMetrics: ScreenMetrics {
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

    /// Returns native pixels in the same orientation as UIKit points for scale calculations.
    private func orientedNativePixelSize(nativeSize: CGSize, pointSize: CGSize) -> CGSize {
        guard nativeSize.width > 0, nativeSize.height > 0 else { return .zero }
        let nativeIsLandscape = nativeSize.width >= nativeSize.height
        let pointsAreLandscape = pointSize.width >= pointSize.height
        if nativeIsLandscape == pointsAreLandscape { return nativeSize }
        return CGSize(width: nativeSize.height, height: nativeSize.width)
    }
}

#endif
