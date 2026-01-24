//
//  MirageCursorType.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/3/26.
//

import Foundation

/// Standard cursor types that can be synchronized between host and client.
/// These map to macOS NSCursor types and are rendered appropriately on each platform.
public enum MirageCursorType: Int, Codable, Sendable, Hashable {
    case arrow = 0              // Default pointer
    case iBeam = 1              // Text selection cursor
    case crosshair = 2          // Precision selection
    case closedHand = 3         // Grabbed/dragging
    case openHand = 4           // Ready to grab
    case pointingHand = 5       // Link/clickable element
    case resizeLeft = 6         // Left edge resize
    case resizeRight = 7        // Right edge resize
    case resizeLeftRight = 8    // Horizontal resize (both directions)
    case resizeUp = 9           // Top edge resize
    case resizeDown = 10        // Bottom edge resize
    case resizeUpDown = 11      // Vertical resize (both directions)
    case disappearingItem = 12  // Dragging item out of valid area
    case operationNotAllowed = 13 // Forbidden/not-allowed action
    case dragLink = 14          // Dragging a link
    case dragCopy = 15          // Dragging with copy modifier
    case contextualMenu = 16    // Context menu available
}

// MARK: - macOS NSCursor Conversion

#if os(macOS)
import AppKit

extension MirageCursorType {
    /// Attempt to identify the cursor type from an NSCursor instance.
    /// Returns nil for custom or unrecognized cursors.
    public init?(from cursor: NSCursor?) {
        guard let cursor = cursor,
              let cursorData = cursor.image.tiffRepresentation else { return nil }

        // Use tiffRepresentation for reliable pixel-data comparison.
        // NSCursor.currentSystem returns a different object reference each time,
        // so reference comparison and NSImage.isEqual(to:) don't work reliably.
        // Comparing TIFF data ensures we match based on actual image content.

        if cursorData == NSCursor.arrow.image.tiffRepresentation {
            self = .arrow
        } else if cursorData == NSCursor.iBeam.image.tiffRepresentation {
            self = .iBeam
        } else if cursorData == NSCursor.crosshair.image.tiffRepresentation {
            self = .crosshair
        } else if cursorData == NSCursor.closedHand.image.tiffRepresentation {
            self = .closedHand
        } else if cursorData == NSCursor.openHand.image.tiffRepresentation {
            self = .openHand
        } else if cursorData == NSCursor.pointingHand.image.tiffRepresentation {
            self = .pointingHand
        } else if cursorData == NSCursor.resizeLeft.image.tiffRepresentation {
            self = .resizeLeft
        } else if cursorData == NSCursor.resizeRight.image.tiffRepresentation {
            self = .resizeRight
        } else if cursorData == NSCursor.resizeLeftRight.image.tiffRepresentation {
            self = .resizeLeftRight
        } else if cursorData == NSCursor.resizeUp.image.tiffRepresentation {
            self = .resizeUp
        } else if cursorData == NSCursor.resizeDown.image.tiffRepresentation {
            self = .resizeDown
        } else if cursorData == NSCursor.resizeUpDown.image.tiffRepresentation {
            self = .resizeUpDown
        } else if cursorData == NSCursor.disappearingItem.image.tiffRepresentation {
            self = .disappearingItem
        } else if cursorData == NSCursor.operationNotAllowed.image.tiffRepresentation {
            self = .operationNotAllowed
        } else if cursorData == NSCursor.dragLink.image.tiffRepresentation {
            self = .dragLink
        } else if cursorData == NSCursor.dragCopy.image.tiffRepresentation {
            self = .dragCopy
        } else if cursorData == NSCursor.contextualMenu.image.tiffRepresentation {
            self = .contextualMenu
        } else {
            // Custom cursor or unrecognized system cursor
            return nil
        }
    }

    /// Get the corresponding NSCursor for this cursor type.
    public var nsCursor: NSCursor {
        switch self {
        case .arrow:
            return .arrow
        case .iBeam:
            return .iBeam
        case .crosshair:
            return .crosshair
        case .closedHand:
            return .closedHand
        case .openHand:
            return .openHand
        case .pointingHand:
            return .pointingHand
        case .resizeLeft:
            return .resizeLeft
        case .resizeRight:
            return .resizeRight
        case .resizeLeftRight:
            return .resizeLeftRight
        case .resizeUp:
            return .resizeUp
        case .resizeDown:
            return .resizeDown
        case .resizeUpDown:
            return .resizeUpDown
        case .disappearingItem:
            return .disappearingItem
        case .operationNotAllowed:
            return .operationNotAllowed
        case .dragLink:
            return .dragLink
        case .dragCopy:
            return .dragCopy
        case .contextualMenu:
            return .contextualMenu
        }
    }
}
#endif

// MARK: - iOS/iPadOS UIPointerStyle Conversion

#if os(iOS)
import UIKit

extension MirageCursorType {
    /// Get the appropriate UIPointerStyle for this cursor type.
    /// - Parameter region: The pointer region for context-aware styling
    /// - Returns: A UIPointerStyle that best represents this cursor type on iPadOS
    public func pointerStyle(for region: UIPointerRegion) -> UIPointerStyle {
        switch self {
        case .arrow, .operationNotAllowed, .contextualMenu:
            // Default system pointer - use automatic behavior
            return UIPointerStyle.system()

        case .iBeam:
            // Text selection cursor - vertical beam
            return UIPointerStyle(shape: .verticalBeam(length: 24))

        case .crosshair:
            // Precision cursor - small plus-shaped indicator
            // iPadOS doesn't have a native crosshair, so we use a small dot
            return UIPointerStyle(shape: .roundedRect(CGRect(x: 0, y: 0, width: 8, height: 8), radius: 4))

        case .closedHand:
            // Grabbing cursor - small circle to indicate active grab
            return UIPointerStyle(shape: .roundedRect(CGRect(x: 0, y: 0, width: 20, height: 20), radius: 10))

        case .openHand, .pointingHand, .dragLink, .dragCopy:
            // Ready-to-grab cursor - slightly larger circle
            return UIPointerStyle(shape: .roundedRect(CGRect(x: 0, y: 0, width: 24, height: 24), radius: 12))

        case .resizeLeft, .resizeRight, .resizeLeftRight:
            // Horizontal resize - horizontal beam indicator
            return UIPointerStyle(shape: .horizontalBeam(length: 24))

        case .resizeUp, .resizeDown, .resizeUpDown:
            // Vertical resize - vertical beam indicator
            return UIPointerStyle(shape: .verticalBeam(length: 24))

        case .disappearingItem:
            // Dragging out of bounds - use small fading indicator
            return UIPointerStyle(shape: .roundedRect(CGRect(x: 0, y: 0, width: 16, height: 16), radius: 8))
        }
    }
}
#endif
