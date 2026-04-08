//
//  DesktopPresentationGeometry.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/7/26.
//

import CoreGraphics

enum DesktopPresentationGeometry {
    static func resolvedContentRect(referenceSize: CGSize?, in bounds: CGRect) -> CGRect {
        guard let referenceSize,
              referenceSize.width > 0,
              referenceSize.height > 0,
              bounds.width > 0,
              bounds.height > 0 else {
            return bounds
        }

        let contentAspect = referenceSize.width / referenceSize.height
        let boundsAspect = bounds.width / bounds.height
        var fittedSize = bounds.size

        if boundsAspect > contentAspect {
            fittedSize.height = bounds.height
            fittedSize.width = fittedSize.height * contentAspect
        } else {
            fittedSize.width = bounds.width
            fittedSize.height = fittedSize.width / contentAspect
        }

        return CGRect(
            x: bounds.minX + (bounds.width - fittedSize.width) * 0.5,
            y: bounds.minY + (bounds.height - fittedSize.height) * 0.5,
            width: fittedSize.width,
            height: fittedSize.height
        )
    }

    static func normalizedPosition(for point: CGPoint, in contentRect: CGRect) -> CGPoint {
        guard contentRect.width > 0, contentRect.height > 0 else { return CGPoint(x: 0.5, y: 0.5) }

        let clampedX = min(max(point.x, contentRect.minX), contentRect.maxX)
        let clampedY = min(max(point.y, contentRect.minY), contentRect.maxY)

        return CGPoint(
            x: (clampedX - contentRect.minX) / contentRect.width,
            y: 1.0 - ((clampedY - contentRect.minY) / contentRect.height)
        )
    }

    static func localPoint(for normalizedPosition: CGPoint, in contentRect: CGRect) -> CGPoint {
        let clampedPosition = clampedNormalizedPosition(normalizedPosition)
        return CGPoint(
            x: contentRect.minX + clampedPosition.x * contentRect.width,
            y: contentRect.minY + (1.0 - clampedPosition.y) * contentRect.height
        )
    }

    static func clampedNormalizedPosition(_ position: CGPoint) -> CGPoint {
        CGPoint(
            x: min(max(position.x, 0), 1),
            y: min(max(position.y, 0), 1)
        )
    }
}
