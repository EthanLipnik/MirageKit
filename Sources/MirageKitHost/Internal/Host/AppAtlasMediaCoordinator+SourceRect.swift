//
//  AppAtlasMediaCoordinator+SourceRect.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/4/26.
//

import CoreGraphics

#if os(macOS)
extension AppAtlasMediaCoordinator {
    /// Returns a finite source rectangle clamped to the captured pixel buffer.
    nonisolated static func normalizedSourceRect(contentRect: CGRect, pixelSize: CGSize) -> CGRect {
        guard pixelSize.width.isFinite,
              pixelSize.height.isFinite,
              pixelSize.width > 0,
              pixelSize.height > 0 else {
            return .zero
        }

        let fullRect = CGRect(origin: .zero, size: pixelSize).integral
        let candidate = contentRect.standardized
        guard candidate.origin.x.isFinite,
              candidate.origin.y.isFinite,
              candidate.width.isFinite,
              candidate.height.isFinite,
              candidate.width > 0,
              candidate.height > 0 else {
            return fullRect
        }

        let clamped = candidate.integral.intersection(fullRect).standardized
        guard clamped.width > 0, clamped.height > 0 else {
            return fullRect
        }
        return clamped
    }

    /// Projects an auxiliary host frame into the parent capture surface.
    nonisolated static func auxiliaryOverlayDestinationRect(
        parentFrame: CGRect,
        parentSourceRect: CGRect,
        auxiliaryFrame: CGRect
    ) -> CGRect {
        let parentBounds = parentSourceRect.standardized.integral
        guard isFiniteNonEmptyRect(parentFrame),
              isFiniteNonEmptyRect(parentBounds),
              isFiniteNonEmptyRect(auxiliaryFrame) else {
            return .zero
        }

        let scaleX = parentBounds.width / parentFrame.width
        let scaleY = parentBounds.height / parentFrame.height
        guard scaleX.isFinite,
              scaleY.isFinite,
              scaleX > 0,
              scaleY > 0 else {
            return .zero
        }

        let proposedRect = CGRect(
            x: parentBounds.minX + ((auxiliaryFrame.minX - parentFrame.minX) * scaleX),
            y: parentBounds.minY + ((auxiliaryFrame.minY - parentFrame.minY) * scaleY),
            width: auxiliaryFrame.width * scaleX,
            height: auxiliaryFrame.height * scaleY
        ).integral
        return clampedOverlayRect(proposedRect, inside: parentBounds)
    }

    /// Converts an overlay destination rectangle into a normalized parent input-routing rectangle.
    nonisolated static func normalizedOverlayInputRect(
        destinationRect: CGRect,
        parentSourceRect: CGRect
    ) -> CGRect {
        let parentBounds = parentSourceRect.standardized.integral
        let destination = destinationRect.standardized
        guard isFiniteNonEmptyRect(parentBounds),
              isFiniteNonEmptyRect(destination) else {
            return .zero
        }
        return CGRect(
            x: (destination.minX - parentBounds.minX) / parentBounds.width,
            y: (destination.minY - parentBounds.minY) / parentBounds.height,
            width: destination.width / parentBounds.width,
            height: destination.height / parentBounds.height
        )
    }

    /// Returns whether a rectangle has finite origin and positive finite size.
    nonisolated static func isFiniteNonEmptyRect(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite &&
            rect.origin.y.isFinite &&
            rect.width.isFinite &&
            rect.height.isFinite &&
            rect.width > 0 &&
            rect.height > 0
    }

    /// Clamps an overlay rectangle inside the parent bounds, scaling oversized overlays to fit.
    private nonisolated static func clampedOverlayRect(_ rect: CGRect, inside bounds: CGRect) -> CGRect {
        guard isFiniteNonEmptyRect(rect),
              isFiniteNonEmptyRect(bounds) else {
            return .zero
        }

        var size = rect.size
        if size.width > bounds.width || size.height > bounds.height {
            let scale = min(bounds.width / size.width, bounds.height / size.height)
            size = CGSize(
                width: max(1, (size.width * scale).rounded(.down)),
                height: max(1, (size.height * scale).rounded(.down))
            )
        }

        var origin = rect.origin
        origin.x = min(max(origin.x, bounds.minX), bounds.maxX - size.width)
        origin.y = min(max(origin.y, bounds.minY), bounds.maxY - size.height)
        return CGRect(origin: origin, size: size).integral
    }
}
#endif
