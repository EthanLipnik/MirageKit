//
//  MirageStreamGeometry.swift
//  MirageMedia
//
//  Created by Ethan Lipnik on 3/31/26.
//

import CoreGraphics
import Foundation

package struct DesktopGeometryIdentity: Sendable, Equatable {
    package let logicalSize: CGSize
    package let displayPixelSize: CGSize
    package let encodedPixelSize: CGSize
    package let disableResolutionCap: Bool

    package init(
        logicalSize: CGSize,
        displayPixelSize: CGSize,
        encodedPixelSize: CGSize,
        disableResolutionCap: Bool
    ) {
        self.logicalSize = DesktopGeometryIdentity.alignedPointSize(logicalSize)
        self.displayPixelSize = DesktopGeometryIdentity.alignedPixelSize(displayPixelSize)
        self.encodedPixelSize = DesktopGeometryIdentity.alignedPixelSize(encodedPixelSize)
        self.disableResolutionCap = disableResolutionCap
    }

    private static func alignedPointSize(_ size: CGSize) -> CGSize {
        MirageStreamGeometry.normalizedLogicalSize(size)
    }

    private static func alignedPixelSize(_ size: CGSize) -> CGSize {
        MirageStreamGeometry.alignedEncodedSize(size)
    }
}

package struct DesktopGeometryContract: Sendable, Equatable {
    package let contractID: UUID
    package let sceneIdentity: String?
    package let refreshTargetHz: Int?
    package let logicalSize: CGSize
    package let requestedDisplayScaleFactor: CGFloat?
    package let acceptedDisplayScaleFactor: CGFloat
    package let displayPixelSize: CGSize
    package let requestedStreamScale: CGFloat
    package let resolvedStreamScale: CGFloat
    package let encodedPixelSize: CGSize
    package let encoderMaxWidth: Int?
    package let encoderMaxHeight: Int?
    package let disableResolutionCap: Bool

    package var identity: DesktopGeometryIdentity {
        DesktopGeometryIdentity(
            logicalSize: logicalSize,
            displayPixelSize: displayPixelSize,
            encodedPixelSize: encodedPixelSize,
            disableResolutionCap: disableResolutionCap
        )
    }

    package init(
        contractID: UUID = UUID(),
        sceneIdentity: String? = nil,
        refreshTargetHz: Int? = nil,
        logicalSize: CGSize,
        requestedDisplayScaleFactor: CGFloat?,
        requestedStreamScale: CGFloat,
        encoderMaxWidth: Int? = nil,
        encoderMaxHeight: Int? = nil,
        disableResolutionCap: Bool = false
    ) {
        let geometry = MirageStreamGeometry.resolve(
            logicalSize: logicalSize,
            displayScaleFactor: requestedDisplayScaleFactor ?? 1.0,
            requestedStreamScale: requestedStreamScale,
            encoderMaxWidth: encoderMaxWidth,
            encoderMaxHeight: encoderMaxHeight,
            disableResolutionCap: disableResolutionCap
        )
        self.init(
            contractID: contractID,
            sceneIdentity: sceneIdentity,
            refreshTargetHz: refreshTargetHz,
            logicalSize: geometry.logicalSize,
            requestedDisplayScaleFactor: requestedDisplayScaleFactor,
            acceptedDisplayScaleFactor: geometry.displayScaleFactor,
            displayPixelSize: geometry.displayPixelSize,
            requestedStreamScale: geometry.requestedStreamScale,
            resolvedStreamScale: geometry.resolvedStreamScale,
            encodedPixelSize: geometry.encodedPixelSize,
            encoderMaxWidth: encoderMaxWidth,
            encoderMaxHeight: encoderMaxHeight,
            disableResolutionCap: disableResolutionCap
        )
    }

    package init(
        contractID: UUID = UUID(),
        sceneIdentity: String? = nil,
        refreshTargetHz: Int? = nil,
        logicalSize: CGSize,
        requestedDisplayScaleFactor: CGFloat?,
        acceptedDisplayScaleFactor: CGFloat,
        displayPixelSize: CGSize,
        requestedStreamScale: CGFloat,
        resolvedStreamScale: CGFloat,
        encodedPixelSize: CGSize,
        encoderMaxWidth: Int?,
        encoderMaxHeight: Int?,
        disableResolutionCap: Bool
    ) {
        self.contractID = contractID
        self.sceneIdentity = sceneIdentity?.isEmpty == false ? sceneIdentity : nil
        self.refreshTargetHz = refreshTargetHz.map { max(1, $0) }
        self.logicalSize = MirageStreamGeometry.normalizedLogicalSize(logicalSize)
        self.requestedDisplayScaleFactor = requestedDisplayScaleFactor.map {
            MirageStreamGeometry.clampedDisplayScaleFactor($0)
        }
        self.acceptedDisplayScaleFactor = MirageStreamGeometry.clampedDisplayScaleFactor(acceptedDisplayScaleFactor)
        self.displayPixelSize = MirageStreamGeometry.alignedEncodedSize(displayPixelSize)
        self.requestedStreamScale = MirageStreamGeometry.clampStreamScale(requestedStreamScale)
        self.resolvedStreamScale = MirageStreamGeometry.clampStreamScale(resolvedStreamScale)
        self.encodedPixelSize = MirageStreamGeometry.alignedEncodedSize(encodedPixelSize)
        self.encoderMaxWidth = encoderMaxWidth
        self.encoderMaxHeight = encoderMaxHeight
        self.disableResolutionCap = disableResolutionCap
    }
}

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

    /// Stream scale after applying encoder limits and resolution caps when enabled.
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
    /// When resolution caps are disabled, the requested scale is authoritative.
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
        let effectiveEncoderMaxWidth = disableResolutionCap ? nil : encoderMaxWidth
        let effectiveEncoderMaxHeight = disableResolutionCap ? nil : encoderMaxHeight
        let widthLimit = positiveEncoderLimit(effectiveEncoderMaxWidth) ?? normalizedBasePixelSize.width
        let heightLimit = positiveEncoderLimit(effectiveEncoderMaxHeight) ?? normalizedBasePixelSize.height
        if disableResolutionCap {
            resolvedScale = clampedRequestedScale
        } else {
            let widthScale = normalizedBasePixelSize.width > 0 ? widthLimit / normalizedBasePixelSize.width : 1.0
            let heightScale = normalizedBasePixelSize.height > 0 ? heightLimit / normalizedBasePixelSize.height : 1.0
            let maxScale = min(1.0, widthScale, heightScale)
            resolvedScale = min(clampedRequestedScale, maxScale)
        }

        let encodedPixelSize = aspectPreservingAlignedEncodedSize(
            scaledSize: CGSize(
                width: normalizedBasePixelSize.width * resolvedScale,
                height: normalizedBasePixelSize.height * resolvedScale
            ),
            basePixelSize: normalizedBasePixelSize,
            widthLimit: widthLimit,
            heightLimit: heightLimit
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

    private static func aspectPreservingAlignedEncodedSize(
        scaledSize: CGSize,
        basePixelSize: CGSize,
        widthLimit: CGFloat,
        heightLimit: CGFloat
    ) -> CGSize {
        let alignedSize = alignedEncodedSize(scaledSize)
        guard basePixelSize.width > 0,
              basePixelSize.height > 0,
              alignedSize.width > 0,
              alignedSize.height > 0 else {
            return alignedSize
        }

        let aspectRatio = basePixelSize.width / basePixelSize.height
        var candidates = [alignedSize]

        let widthFromHeight = CGFloat(alignedEncodedDimension(alignedSize.height * aspectRatio))
        if widthFromHeight <= alignedSize.width, widthFromHeight <= widthLimit {
            candidates.append(CGSize(width: widthFromHeight, height: alignedSize.height))
        }

        let heightFromWidth = CGFloat(alignedEncodedDimension(alignedSize.width / aspectRatio))
        if heightFromWidth <= alignedSize.height, heightFromWidth <= heightLimit {
            candidates.append(CGSize(width: alignedSize.width, height: heightFromWidth))
        }

        return candidates.min { lhs, rhs in
            let lhsAspectError = abs((lhs.width / lhs.height) - aspectRatio)
            let rhsAspectError = abs((rhs.width / rhs.height) - aspectRatio)
            if abs(lhsAspectError - rhsAspectError) > 0.0001 {
                return lhsAspectError < rhsAspectError
            }
            return lhs.width * lhs.height > rhs.width * rhs.height
        } ?? alignedSize
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
