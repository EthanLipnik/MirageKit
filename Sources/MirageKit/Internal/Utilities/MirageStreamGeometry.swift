//
//  MirageStreamGeometry.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/31/26.
//

import CoreGraphics
import Foundation

/// Canonical stream sizing result shared by client display requests and host encoder setup.
package struct MirageStreamGeometry: Sendable, Equatable {
    /// Logical point size after Mirage's even-dimension normalization.
    package let logicalSize: CGSize

    /// Effective display scale inferred from the normalized logical and pixel sizes.
    package let displayScaleFactor: CGFloat

    /// Native display pixel size aligned for encoder compatibility.
    package let displayPixelSize: CGSize

    /// Caller-requested stream scale after clamping to Mirage's supported range.
    package let requestedStreamScale: CGFloat

    /// Stream scale after applying encoder limits and resolution caps.
    package let resolvedStreamScale: CGFloat

    /// Final encoded pixel size after scale resolution and encoder alignment.
    package let encodedPixelSize: CGSize

    /// Normalizes logical point sizes to positive even dimensions.
    package static func normalizedLogicalSize(_ size: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return .zero }
        return CGSize(
            width: CGFloat(normalizedLogicalDimension(size.width)),
            height: CGFloat(normalizedLogicalDimension(size.height))
        )
    }

    /// Resolves logical display geometry and encoded stream geometry in one pass.
    package static func resolve(
        logicalSize: CGSize,
        displayScaleFactor: CGFloat,
        requestedStreamScale: CGFloat = 1.0,
        encoderMaxWidth: Int? = nil,
        encoderMaxHeight: Int? = nil,
        disableResolutionCap: Bool = false
    ) -> MirageStreamGeometry {
        let normalizedLogicalSize = normalizedLogicalSize(logicalSize)
        let requestedDisplayScale = clampedDisplayScaleFactor(displayScaleFactor)
        let displayPixelSize = alignedEncodedSize(
            CGSize(
                width: normalizedLogicalSize.width * requestedDisplayScale,
                height: normalizedLogicalSize.height * requestedDisplayScale
            )
        )
        let resolvedDisplayScale = inferredDisplayScaleFactor(
            logicalSize: normalizedLogicalSize,
            pixelSize: displayPixelSize,
            fallback: requestedDisplayScale
        )
        let encodedPlan = resolveEncodedPlan(
            basePixelSize: displayPixelSize,
            requestedStreamScale: requestedStreamScale,
            encoderMaxWidth: encoderMaxWidth,
            encoderMaxHeight: encoderMaxHeight,
            disableResolutionCap: disableResolutionCap
        )

        return MirageStreamGeometry(
            logicalSize: normalizedLogicalSize,
            displayScaleFactor: resolvedDisplayScale,
            displayPixelSize: displayPixelSize,
            requestedStreamScale: encodedPlan.requestedStreamScale,
            resolvedStreamScale: encodedPlan.resolvedStreamScale,
            encodedPixelSize: encodedPlan.encodedPixelSize
        )
    }

    /// Resolves encoded stream size from a pixel-size base and optional encoder limits.
    package static func resolveEncodedPlan(
        basePixelSize: CGSize,
        requestedStreamScale: CGFloat = 1.0,
        encoderMaxWidth: Int? = nil,
        encoderMaxHeight: Int? = nil,
        disableResolutionCap: Bool = false
    ) -> MirageStreamGeometry {
        let normalizedBasePixelSize = alignedEncodedSize(basePixelSize)
        let clampedRequestedScale = clampStreamScale(requestedStreamScale)
        let requestedScaleLimit: CGFloat
        let widthLimit = positiveEncoderLimit(encoderMaxWidth) ?? normalizedBasePixelSize.width
        let heightLimit = positiveEncoderLimit(encoderMaxHeight) ?? normalizedBasePixelSize.height
        let hasExplicitResolutionLimit = positiveEncoderLimit(encoderMaxWidth) != nil ||
            positiveEncoderLimit(encoderMaxHeight) != nil
        if disableResolutionCap && !hasExplicitResolutionLimit {
            requestedScaleLimit = clampedRequestedScale
        } else {
            let widthScale = normalizedBasePixelSize.width > 0 ? widthLimit / normalizedBasePixelSize.width : 1.0
            let heightScale = normalizedBasePixelSize.height > 0 ? heightLimit / normalizedBasePixelSize.height : 1.0
            let maxScale = min(1.0, widthScale, heightScale)
            requestedScaleLimit = min(clampedRequestedScale, maxScale)
        }

        let alignedPlan = aspectPreservingAlignedEncodedPlan(
            basePixelSize: normalizedBasePixelSize,
            requestedScaleLimit: requestedScaleLimit
        )

        return MirageStreamGeometry(
            logicalSize: .zero,
            displayScaleFactor: 1.0,
            displayPixelSize: normalizedBasePixelSize,
            requestedStreamScale: clampedRequestedScale,
            resolvedStreamScale: alignedPlan.scale,
            encodedPixelSize: alignedPlan.encodedPixelSize
        )
    }

    /// Aligns a size to encoder-safe dimensions.
    package static func alignedEncodedSize(_ size: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return .zero }
        return CGSize(
            width: CGFloat(alignedEncodedDimension(size.width)),
            height: CGFloat(alignedEncodedDimension(size.height))
        )
    }

    /// Rounds a dimension down to the nearest 16-pixel encoder boundary.
    package static func alignedEncodedDimension(_ value: CGFloat) -> Int {
        let rounded = Int(value.rounded())
        let aligned = rounded & ~15
        return max(aligned, 16)
    }

    /// Clamps stream scale to Mirage's supported range.
    package static func clampStreamScale(_ scale: CGFloat) -> CGFloat {
        guard scale > 0 else { return 1.0 }
        return max(0.1, min(1.0, scale))
    }

    /// Clamps optional display scale factors to a valid positive display scale.
    package static func clampedDisplayScaleFactor(_ value: CGFloat?) -> CGFloat {
        max(1.0, value ?? 1.0)
    }

    private static func normalizedLogicalDimension(_ value: CGFloat) -> Int {
        let rounded = Int(value.rounded(.down))
        let even = rounded - (rounded % 2)
        return max(even, 2)
    }

    private static func positiveEncoderLimit(_ value: Int?) -> CGFloat? {
        guard let value, value > 0 else { return nil }
        return CGFloat(value)
    }

    private struct EncodedScalePlan {
        let scale: CGFloat
        let encodedPixelSize: CGSize
    }

    private static func aspectPreservingAlignedEncodedPlan(
        basePixelSize: CGSize,
        requestedScaleLimit: CGFloat
    ) -> EncodedScalePlan {
        guard basePixelSize.width > 0,
              basePixelSize.height > 0,
              requestedScaleLimit > 0 else {
            return EncodedScalePlan(scale: 1.0, encodedPixelSize: .zero)
        }

        let scaledWidth = basePixelSize.width * requestedScaleLimit
        let scaledHeight = basePixelSize.height * requestedScaleLimit
        let alignedWidth = CGFloat(alignedEncodedDimension(scaledWidth))
        let alignedHeight = CGFloat(alignedEncodedDimension(scaledHeight))
        let aspect = basePixelSize.width / basePixelSize.height

        let widthAnchoredHeight = min(
            alignedHeight,
            CGFloat(alignedEncodedDimension(alignedWidth / aspect))
        )
        let widthAnchored = EncodedScalePlan(
            scale: alignedWidth / basePixelSize.width,
            encodedPixelSize: CGSize(width: alignedWidth, height: widthAnchoredHeight)
        )

        let heightAnchoredWidth = min(
            alignedWidth,
            CGFloat(alignedEncodedDimension(alignedHeight * aspect))
        )
        let heightAnchored = EncodedScalePlan(
            scale: alignedHeight / basePixelSize.height,
            encodedPixelSize: CGSize(width: heightAnchoredWidth, height: alignedHeight)
        )

        return [widthAnchored, heightAnchored]
            .filter { $0.encodedPixelSize.width > 0 && $0.encodedPixelSize.height > 0 }
            .min { lhs, rhs in
                let lhsAspect = lhs.encodedPixelSize.width / lhs.encodedPixelSize.height
                let rhsAspect = rhs.encodedPixelSize.width / rhs.encodedPixelSize.height
                let lhsError = abs(lhsAspect - aspect) / aspect
                let rhsError = abs(rhsAspect - aspect) / aspect
                if abs(lhsError - rhsError) > 0.0001 {
                    return lhsError < rhsError
                }

                let lhsArea = lhs.encodedPixelSize.width * lhs.encodedPixelSize.height
                let rhsArea = rhs.encodedPixelSize.width * rhs.encodedPixelSize.height
                return lhsArea > rhsArea
            } ?? EncodedScalePlan(
                scale: requestedScaleLimit,
                encodedPixelSize: alignedEncodedSize(
                    CGSize(width: scaledWidth, height: scaledHeight)
                )
            )
    }

    private static func inferredDisplayScaleFactor(
        logicalSize: CGSize,
        pixelSize: CGSize,
        fallback: CGFloat
    ) -> CGFloat {
        guard logicalSize.width > 0,
              logicalSize.height > 0,
              pixelSize.width > 0,
              pixelSize.height > 0 else {
            return fallback
        }
        let widthScale = pixelSize.width / logicalSize.width
        let heightScale = pixelSize.height / logicalSize.height
        guard widthScale > 0, heightScale > 0 else { return fallback }
        return max(1.0, (widthScale + heightScale) * 0.5)
    }
}
