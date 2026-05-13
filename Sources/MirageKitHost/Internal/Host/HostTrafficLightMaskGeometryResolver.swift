//
//  HostTrafficLightMaskGeometryResolver.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/1/26.
//

import CoreGraphics
import Foundation
import MirageKit

#if os(macOS)
import ApplicationServices

/// Resolves host-side traffic-light geometry for visual masking.
enum HostTrafficLightMaskGeometryResolver {
    /// Source used for resolved traffic-light mask geometry.
    enum Source: String {
        case ax
        case fallback
    }

    /// Traffic-light cluster geometry in host-window point coordinates.
    struct ResolvedGeometry {
        let windowFramePoints: CGRect
        let clusterRectPoints: CGRect
        let buttonUnionRectInClusterPoints: CGRect?
        let source: Source

        init(
            windowFramePoints: CGRect,
            clusterRectPoints: CGRect,
            buttonUnionRectInClusterPoints: CGRect? = nil,
            source: Source
        ) {
            self.windowFramePoints = windowFramePoints
            self.clusterRectPoints = clusterRectPoints
            self.buttonUnionRectInClusterPoints = buttonUnionRectInClusterPoints
            self.source = source
        }
    }

    /// Cached traffic-light mask geometry for a sampled window frame.
    struct CacheEntry {
        let geometry: ResolvedGeometry
        let sampledAt: CFAbsoluteTime
        let sampledWindowFrame: CGRect
    }

    private static let clusterTrailingPadding: CGFloat = 10
    private static let clusterBottomPadding: CGFloat = 8
    private static let maxClusterWidth: CGFloat = 220
    private static let maxClusterHeight: CGFloat = 120

    /// Resolves the best available traffic-light mask geometry for a window.
    static func resolve(
        windowID: WindowID,
        windowFramePoints: CGRect,
        appProcessID: pid_t?
    ) -> ResolvedGeometry {
        let fallbackRect = fallbackClusterRect(in: windowFramePoints)

        guard let axWindow = HostAccessibilityWindowLookup.resolveWindow(
            windowID: windowID,
            processID: appProcessID
        ) else {
            return ResolvedGeometry(
                windowFramePoints: windowFramePoints,
                clusterRectPoints: fallbackRect,
                source: .fallback
            )
        }

        guard let clusterGeometry = dynamicClusterGeometry(in: axWindow, windowFramePoints: windowFramePoints) else {
            return ResolvedGeometry(
                windowFramePoints: windowFramePoints,
                clusterRectPoints: fallbackRect,
                source: .fallback
            )
        }

        return ResolvedGeometry(
            windowFramePoints: windowFramePoints,
            clusterRectPoints: clusterGeometry.clusterRectPoints,
            buttonUnionRectInClusterPoints: clusterGeometry.buttonUnionRectInClusterPoints,
            source: .ax
        )
    }

    /// Returns whether cached geometry is fresh and frame-compatible.
    static func shouldUseCached(
        _ cache: CacheEntry,
        now: CFAbsoluteTime,
        windowFramePoints: CGRect,
        ttl: CFAbsoluteTime,
        frameTolerance: CGFloat
    ) -> Bool {
        if now - cache.sampledAt > ttl {
            return false
        }
        return framesAreClose(cache.sampledWindowFrame, windowFramePoints, tolerance: frameTolerance)
    }

    /// Returns whether two frames are close enough for cache reuse.
    static func framesAreClose(
        _ lhs: CGRect,
        _ rhs: CGRect,
        tolerance: CGFloat
    ) -> Bool {
        abs(lhs.origin.x - rhs.origin.x) <= tolerance &&
            abs(lhs.origin.y - rhs.origin.y) <= tolerance &&
            abs(lhs.size.width - rhs.size.width) <= tolerance &&
            abs(lhs.size.height - rhs.size.height) <= tolerance
    }

    /// Returns conservative fallback traffic-light cluster bounds.
    static func fallbackClusterRect(in windowFramePoints: CGRect) -> CGRect {
        let fallback = HostTrafficLightProtectionPolicy.fallbackClusterSize
        guard windowFramePoints.width > 0, windowFramePoints.height > 0 else {
            return CGRect(origin: .zero, size: fallback)
        }

        let width = min(windowFramePoints.width, fallback.width)
        let height = min(windowFramePoints.height, fallback.height)
        return CGRect(x: 0, y: 0, width: width, height: height)
    }

    /// AX-derived cluster geometry from traffic-light button frames.
    struct DynamicClusterGeometry {
        let clusterRectPoints: CGRect
        let buttonUnionRectInClusterPoints: CGRect
    }

    /// Resolves traffic-light geometry from live AX button frames.
    static func dynamicClusterGeometry(in axWindow: AXUIElement, windowFramePoints: CGRect) -> DynamicClusterGeometry? {
        let buttonFrames = HostAccessibilityWindowLookup.trafficLightButtonFrames(in: axWindow)
        return clusterGeometryFromButtonFrames(buttonFrames, windowFramePoints: windowFramePoints)
    }

    /// Builds cluster geometry from AX button frames.
    static func clusterGeometryFromButtonFrames(
        _ buttonFrames: [CGRect],
        windowFramePoints: CGRect
    ) -> DynamicClusterGeometry? {
        guard !buttonFrames.isEmpty else { return nil }

        guard let firstButtonFrame = buttonFrames.first else { return nil }
        let unionRect = buttonFrames.dropFirst().reduce(firstButtonFrame) { partial, next in
            partial.union(next)
        }

        let leadingInset = max(0, unionRect.minX - windowFramePoints.minX)
        let topInsetFromMinY = max(0, unionRect.minY - windowFramePoints.minY)
        let topInsetFromMaxY = max(0, windowFramePoints.maxY - unionRect.maxY)
        let inferredTopInset = min(topInsetFromMinY, topInsetFromMaxY)

        let fallback = HostTrafficLightProtectionPolicy.fallbackClusterSize
        let clusterWidth = max(
            fallback.width,
            leadingInset + unionRect.width + clusterTrailingPadding
        )
        let clusterHeight = max(
            fallback.height,
            inferredTopInset + unionRect.height + clusterBottomPadding
        )

        let clampedWidth = min(windowFramePoints.width, min(maxClusterWidth, clusterWidth))
        let clampedHeight = min(windowFramePoints.height, min(maxClusterHeight, clusterHeight))
        guard clampedWidth > 0, clampedHeight > 0 else { return nil }

        let clusterRect = CGRect(x: 0, y: 0, width: clampedWidth, height: clampedHeight)

        let unionX = min(max(leadingInset, 0), max(0, clampedWidth - 1))
        let unionY = min(max(inferredTopInset, 0), max(0, clampedHeight - 1))
        let unionWidth = min(unionRect.width, clampedWidth - unionX)
        let unionHeight = min(unionRect.height, clampedHeight - unionY)
        guard unionWidth > 0, unionHeight > 0 else { return nil }

        let buttonUnionRectInCluster = CGRect(
            x: unionX,
            y: unionY,
            width: unionWidth,
            height: unionHeight
        )

        return DynamicClusterGeometry(
            clusterRectPoints: clusterRect,
            buttonUnionRectInClusterPoints: buttonUnionRectInCluster
        )
    }

}
#endif
