//
//  InputCapturingView+CursorGeometry.swift
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
#if os(iOS) || os(visionOS)
import UIKit

extension InputCapturingView {
    /// Returns the video content rect used to convert between local points and normalized host coordinates.
    func resolvedPresentationContentRect() -> CGRect {
        sampleBufferView.resolvedPresentedContentRect(in: bounds)
    }

    /// Converts a local UIKit point into the normalized stream coordinate space.
    nonisolated static func normalizedLocation(
        _ point: CGPoint,
        in bounds: CGRect,
        contentRect: CGRect? = nil
    ) -> CGPoint {
        let resolvedContentRect = (contentRect ?? bounds).standardized
        guard resolvedContentRect.width > 0, resolvedContentRect.height > 0 else {
            return CGPoint(x: 0.5, y: 0.5)
        }

        let clampedX = min(max(point.x, resolvedContentRect.minX), resolvedContentRect.maxX)
        let clampedY = min(max(point.y, resolvedContentRect.minY), resolvedContentRect.maxY)
        return CGPoint(
            x: (clampedX - resolvedContentRect.minX) / resolvedContentRect.width,
            y: (clampedY - resolvedContentRect.minY) / resolvedContentRect.height
        )
    }

    /// Converts a normalized stream coordinate into a local UIKit point.
    nonisolated static func localPoint(
        forNormalizedPosition position: CGPoint,
        in bounds: CGRect,
        contentRect: CGRect? = nil
    ) -> CGPoint {
        let resolvedContentRect = (contentRect ?? bounds).standardized
        guard resolvedContentRect.width > 0, resolvedContentRect.height > 0 else {
            return CGPoint(x: bounds.midX, y: bounds.midY)
        }

        let clampedPosition = DesktopPresentationGeometry.clampedNormalizedPosition(position)
        return CGPoint(
            x: resolvedContentRect.minX + clampedPosition.x * resolvedContentRect.width,
            y: resolvedContentRect.minY + clampedPosition.y * resolvedContentRect.height
        )
    }
}
#endif
