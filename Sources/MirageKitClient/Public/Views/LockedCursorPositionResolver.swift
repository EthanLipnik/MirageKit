//
//  LockedCursorPositionResolver.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/5/26.
//

import CoreGraphics

enum LockedCursorPositionResolver {
    private static let speculativeExtendedBoundsAllowance: CGFloat = 0.35

    static func applyRelativeDelta(
        currentPosition: CGPoint,
        deltaX: CGFloat,
        deltaY: CGFloat,
        normalizationSize: CGSize,
        allowsExtendedBounds: Bool,
        confirmedHostPosition: CGPoint? = nil
    ) -> CGPoint {
        guard normalizationSize.width > 0, normalizationSize.height > 0 else {
            return currentPosition
        }

        let proposedPosition = CGPoint(
            x: currentPosition.x + deltaX / normalizationSize.width,
            y: currentPosition.y + deltaY / normalizationSize.height
        )
        return resolve(
            proposedPosition,
            allowsExtendedBounds: allowsExtendedBounds,
            confirmedHostPosition: confirmedHostPosition
        )
    }

    static func resolve(
        _ position: CGPoint,
        allowsExtendedBounds: Bool,
        confirmedHostPosition: CGPoint? = nil
    ) -> CGPoint {
        guard allowsExtendedBounds else { return inBoundsPosition(position) }
        let baselinePosition = confirmedHostPosition ?? inBoundsPosition(position)

        let minX = min(0, baselinePosition.x) - speculativeExtendedBoundsAllowance
        let maxX = max(1, baselinePosition.x) + speculativeExtendedBoundsAllowance
        let minY = min(0, baselinePosition.y) - speculativeExtendedBoundsAllowance
        let maxY = max(1, baselinePosition.y) + speculativeExtendedBoundsAllowance

        return CGPoint(
            x: min(max(position.x, minX), maxX),
            y: min(max(position.y, minY), maxY)
        )
    }

    private static func inBoundsPosition(_ position: CGPoint) -> CGPoint {
        CGPoint(
            x: min(max(position.x, 0), 1),
            y: min(max(position.y, 0), 1)
        )
    }
}
