//
//  MirageStreamGeometry.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/31/26.
//

import CoreGraphics
import Foundation

package struct MirageStreamGeometry: Sendable, Equatable {
    package let logicalSize: CGSize
    package let displayScaleFactor: CGFloat
    package let displayPixelSize: CGSize
    package let requestedStreamScale: CGFloat
    package let resolvedStreamScale: CGFloat
    package let encodedPixelSize: CGSize

    package static func normalizedLogicalSize(_ size: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return .zero }
        return CGSize(
            width: CGFloat(normalizedLogicalDimension(size.width)),
            height: CGFloat(normalizedLogicalDimension(size.height))
        )
    }

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

    package static func resolveEncodedPlan(
        basePixelSize: CGSize,
        requestedStreamScale: CGFloat = 1.0,
        encoderMaxWidth: Int? = nil,
        encoderMaxHeight: Int? = nil,
        disableResolutionCap: Bool = false
    ) -> MirageStreamGeometry {
        let normalizedBasePixelSize = alignedEncodedSize(basePixelSize)
        let clampedRequestedScale = clampStreamScale(requestedStreamScale)
        let resolvedScale: CGFloat
        let widthLimit = positiveEncoderLimit(encoderMaxWidth) ?? normalizedBasePixelSize.width
        let heightLimit = positiveEncoderLimit(encoderMaxHeight) ?? normalizedBasePixelSize.height
        let hasExplicitResolutionLimit = positiveEncoderLimit(encoderMaxWidth) != nil ||
            positiveEncoderLimit(encoderMaxHeight) != nil
        if disableResolutionCap && !hasExplicitResolutionLimit {
            resolvedScale = clampedRequestedScale
        } else {
            let widthScale = normalizedBasePixelSize.width > 0 ? widthLimit / normalizedBasePixelSize.width : 1.0
            let heightScale = normalizedBasePixelSize.height > 0 ? heightLimit / normalizedBasePixelSize.height : 1.0
            let maxScale = min(1.0, widthScale, heightScale)
            resolvedScale = min(clampedRequestedScale, maxScale)
        }

        let encodedPixelSize = alignedEncodedSize(
            CGSize(
                width: normalizedBasePixelSize.width * resolvedScale,
                height: normalizedBasePixelSize.height * resolvedScale
            )
        )

        return MirageStreamGeometry(
            logicalSize: .zero,
            displayScaleFactor: 1.0,
            displayPixelSize: normalizedBasePixelSize,
            requestedStreamScale: clampedRequestedScale,
            resolvedStreamScale: resolvedScale,
            encodedPixelSize: encodedPixelSize
        )
    }

    package static func alignedEncodedSize(_ size: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return .zero }
        return CGSize(
            width: CGFloat(alignedEncodedDimension(size.width)),
            height: CGFloat(alignedEncodedDimension(size.height))
        )
    }

    package static func alignedEncodedDimension(_ value: CGFloat) -> Int {
        let rounded = Int(value.rounded())
        let aligned = rounded & ~15
        return max(aligned, 16)
    }

    package static func clampStreamScale(_ scale: CGFloat) -> CGFloat {
        guard scale > 0 else { return 1.0 }
        return max(0.1, min(1.0, scale))
    }

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
