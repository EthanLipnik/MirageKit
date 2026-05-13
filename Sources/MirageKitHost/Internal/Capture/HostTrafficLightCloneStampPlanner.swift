//
//  HostTrafficLightCloneStampPlanner.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/10/26.
//
//  Geometry planning for traffic-light clone stamping.
//

import CoreGraphics
import CoreVideo
import Foundation

#if os(macOS)
/// Pixel-space source, destination, and mask regions for clone-stamping protected traffic-light UI.
struct HostTrafficLightCloneStampPlan: Sendable {
    let destinationRect: CGRect
    let sourceRect: CGRect
    let maskRect: CGRect
    let featherPixels: Float
    let blurRadiusPixels: Float
    let blendStrength: Float

    /// Returns the plan transformed into a texture plane's coordinate space.
    func scaled(x scaleX: CGFloat, y scaleY: CGFloat) -> HostTrafficLightCloneStampPlan {
        HostTrafficLightCloneStampPlan(
            destinationRect: CGRect(
                x: destinationRect.origin.x * scaleX,
                y: destinationRect.origin.y * scaleY,
                width: destinationRect.width * scaleX,
                height: destinationRect.height * scaleY
            ),
            sourceRect: CGRect(
                x: sourceRect.origin.x * scaleX,
                y: sourceRect.origin.y * scaleY,
                width: sourceRect.width * scaleX,
                height: sourceRect.height * scaleY
            ),
            maskRect: CGRect(
                x: maskRect.origin.x * scaleX,
                y: maskRect.origin.y * scaleY,
                width: maskRect.width * scaleX,
                height: maskRect.height * scaleY
            ),
            featherPixels: featherPixels,
            blurRadiusPixels: blurRadiusPixels,
            blendStrength: blendStrength
        )
    }
}

/// Converts traffic-light geometry into clone-stamp regions without touching Metal state.
enum HostTrafficLightCloneStampPlanner {
    enum SkipReason: String, Sendable {
        case unsupportedPixelFormat
        case invalidContentRect
        case invalidWindowFrame
        case emptyDestination
        case emptySource
    }

    enum Decision: Sendable {
        case apply(HostTrafficLightCloneStampPlan)
        case skip(SkipReason)
    }

    private static let minimumDestinationSize: CGFloat = 4
    private static let minimumMaskSize: CGFloat = 4
    private static let minimumSourceThickness: CGFloat = 1
    private static let maximumSourceThickness: CGFloat = 4
    private static let sourceGap: CGFloat = 1

    /// Builds a clone-stamp plan for a captured frame, or returns the reason stamping should be skipped.
    static func makeDecision(
        pixelFormat: OSType,
        contentRect: CGRect,
        geometry: HostTrafficLightMaskGeometryResolver.ResolvedGeometry
    ) -> Decision {
        guard isSupportedPixelFormat(pixelFormat) else {
            return .skip(.unsupportedPixelFormat)
        }
        guard contentRect.width > 0, contentRect.height > 0 else {
            return .skip(.invalidContentRect)
        }
        guard geometry.windowFramePoints.width > 0, geometry.windowFramePoints.height > 0 else {
            return .skip(.invalidWindowFrame)
        }
        let scaleX = contentRect.width / geometry.windowFramePoints.width
        let scaleY = contentRect.height / geometry.windowFramePoints.height

        var destinationRect = CGRect(
            x: contentRect.minX + geometry.clusterRectPoints.minX * scaleX,
            y: contentRect.minY + geometry.clusterRectPoints.minY * scaleY,
            width: geometry.clusterRectPoints.width * scaleX,
            height: geometry.clusterRectPoints.height * scaleY
        )
        destinationRect = destinationRect.intersection(contentRect)

        guard destinationRect.width >= minimumDestinationSize,
              destinationRect.height >= minimumDestinationSize else {
            return .skip(.emptyDestination)
        }

        let sourceThickness = max(
            minimumSourceThickness,
            min(maximumSourceThickness, floor(destinationRect.height * 0.06))
        )

        let rightCandidate = CGRect(
            x: destinationRect.maxX + sourceGap,
            y: destinationRect.minY,
            width: sourceThickness,
            height: destinationRect.height
        )
        let belowCandidate = CGRect(
            x: destinationRect.minX,
            y: destinationRect.maxY + sourceGap,
            width: destinationRect.width,
            height: sourceThickness
        )

        let sourceRect: CGRect
        if contains(rightCandidate, in: contentRect) {
            sourceRect = rightCandidate
        } else if contains(belowCandidate, in: contentRect) {
            sourceRect = belowCandidate
        } else {
            let clampedRight = clampedRect(rightCandidate, in: contentRect)
            let clampedBelow = clampedRect(belowCandidate, in: contentRect)
            if clampedRight.width * clampedRight.height >= clampedBelow.width * clampedBelow.height {
                sourceRect = clampedRight
            } else {
                sourceRect = clampedBelow
            }
        }

        guard sourceRect.width >= minimumSourceThickness,
              sourceRect.height >= minimumSourceThickness,
              max(sourceRect.width, sourceRect.height) >= minimumDestinationSize else {
            return .skip(.emptySource)
        }

        let maskRect = resolvedMaskRect(destinationRect: destinationRect, geometry: geometry)
        guard maskRect.width >= minimumMaskSize, maskRect.height >= minimumMaskSize else {
            return .skip(.emptyDestination)
        }

        let featherPixels = Float(max(1.25, min(3.4, maskRect.height * 0.18)))
        let blurRadiusPixels = Float(max(0.45, min(1.1, maskRect.height * 0.06)))

        return .apply(
            HostTrafficLightCloneStampPlan(
                destinationRect: destinationRect,
                sourceRect: sourceRect,
                maskRect: maskRect,
                featherPixels: featherPixels,
                blurRadiusPixels: blurRadiusPixels,
                blendStrength: 1.0
            )
        )
    }

    /// Returns true when the compositor can create Metal textures for the captured buffer format.
    static func isSupportedPixelFormat(_ pixelFormat: OSType) -> Bool {
        switch pixelFormat {
        case kCVPixelFormatType_32BGRA,
             kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
             kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
             kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
             kCVPixelFormatType_444YpCbCr10BiPlanarFullRange:
            return true
        default:
            return false
        }
    }

    private static func contains(_ candidate: CGRect, in rect: CGRect) -> Bool {
        candidate.minX >= rect.minX &&
            candidate.minY >= rect.minY &&
            candidate.maxX <= rect.maxX &&
            candidate.maxY <= rect.maxY
    }

    private static func clampedRect(_ rect: CGRect, in bounds: CGRect) -> CGRect {
        guard bounds.width > 0, bounds.height > 0 else { return .zero }

        let width = min(rect.width, bounds.width)
        let height = min(rect.height, bounds.height)
        let x = min(max(rect.minX, bounds.minX), bounds.maxX - width)
        let y = min(max(rect.minY, bounds.minY), bounds.maxY - height)

        return CGRect(x: x, y: y, width: width, height: height)
    }

    private static func resolvedMaskRect(
        destinationRect: CGRect,
        geometry: HostTrafficLightMaskGeometryResolver.ResolvedGeometry
    ) -> CGRect {
        if let buttonUnionRectInCluster = geometry.buttonUnionRectInClusterPoints,
           geometry.clusterRectPoints.width > 0,
           geometry.clusterRectPoints.height > 0 {
            let scaleX = destinationRect.width / geometry.clusterRectPoints.width
            let scaleY = destinationRect.height / geometry.clusterRectPoints.height
            let axMaskRect = CGRect(
                x: destinationRect.minX + buttonUnionRectInCluster.minX * scaleX,
                y: destinationRect.minY + buttonUnionRectInCluster.minY * scaleY,
                width: buttonUnionRectInCluster.width * scaleX,
                height: buttonUnionRectInCluster.height * scaleY
            ).intersection(destinationRect)
            let paddedAXMaskRect = axMaskRect
                .insetBy(dx: -1.5, dy: -1.5)
                .intersection(destinationRect)
            if paddedAXMaskRect.width >= minimumMaskSize, paddedAXMaskRect.height >= minimumMaskSize {
                return paddedAXMaskRect
            }
            if axMaskRect.width >= minimumMaskSize, axMaskRect.height >= minimumMaskSize {
                return axMaskRect
            }
        }

        let fallbackInsetX = max(2, destinationRect.height * 0.14)
        let fallbackInsetY = max(2, destinationRect.height * 0.14)
        let fallbackHeight = max(minimumMaskSize, min(destinationRect.height * 0.52, destinationRect.height - fallbackInsetY))
        let fallbackWidth = max(
            minimumMaskSize,
            min(destinationRect.width - fallbackInsetX, fallbackHeight * 3.8)
        )

        return CGRect(
            x: destinationRect.minX + fallbackInsetX,
            y: destinationRect.minY + fallbackInsetY,
            width: fallbackWidth,
            height: fallbackHeight
        ).intersection(destinationRect)
    }
}
#endif
