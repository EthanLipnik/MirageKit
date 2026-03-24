//
//  HostTrafficLightProtectionPolicy.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/28/26.
//
//  Traffic-light cluster blocking policy for remote pointer input.
//

import CoreGraphics

#if os(macOS)
enum HostTrafficLightProtectionPolicy {
    static let fallbackClusterSize = CGSize(width: 76, height: 38)

    private static let protectedPointerEventTypes: Set<CGEventType> = [
        .mouseMoved,
        .leftMouseDown,
        .leftMouseUp,
        .leftMouseDragged,
        .rightMouseDown,
        .rightMouseUp,
        .rightMouseDragged,
        .otherMouseDown,
        .otherMouseUp,
        .otherMouseDragged,
    ]

    static func shouldBlock(
        eventType: CGEventType,
        localPoint: CGPoint,
        dynamicClusterSize: CGSize?
    ) -> Bool {
        guard protectedPointerEventTypes.contains(eventType) else { return false }

        let effectiveSize = effectiveClusterSize(dynamicClusterSize: dynamicClusterSize)
        guard effectiveSize.width > 0, effectiveSize.height > 0 else { return false }

        return localPoint.x >= 0 &&
            localPoint.y >= 0 &&
            localPoint.x <= effectiveSize.width &&
            localPoint.y <= effectiveSize.height
    }

    static func effectiveClusterSize(dynamicClusterSize: CGSize?) -> CGSize {
        guard let dynamicClusterSize,
              dynamicClusterSize.width.isFinite,
              dynamicClusterSize.height.isFinite,
              dynamicClusterSize.width > 0,
              dynamicClusterSize.height > 0 else {
            return fallbackClusterSize
        }

        // Trust the dynamically measured cluster size when available rather
        // than inflating it with max(fallback, dynamic).  The fallback is only
        // used when AX geometry is unavailable.
        return dynamicClusterSize
    }
}
#endif
