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
    case arrow = 0 // Default pointer
    case iBeam = 1 // Text selection cursor
    case crosshair = 2 // Precision selection
    case closedHand = 3 // Grabbed/dragging
    case openHand = 4 // Ready to grab
    case pointingHand = 5 // Link/clickable element
    case resizeLeft = 6 // Left edge resize
    case resizeRight = 7 // Right edge resize
    case resizeLeftRight = 8 // Horizontal resize (both directions)
    case resizeUp = 9 // Top edge resize
    case resizeDown = 10 // Bottom edge resize
    case resizeUpDown = 11 // Vertical resize (both directions)
    case disappearingItem = 12 // Dragging item out of valid area
    case operationNotAllowed = 13 // Forbidden/not-allowed action
    case dragLink = 14 // Dragging a link
    case dragCopy = 15 // Dragging with copy modifier
    case contextualMenu = 16 // Context menu available
    case resizeNorthEast = 17 // NE corner resize
    case resizeNorthWest = 18 // NW corner resize
    case resizeSouthEast = 19 // SE corner resize
    case resizeSouthWest = 20 // SW corner resize
    case resizeNESW = 21 // NE/SW bidirectional diagonal
    case resizeNWSE = 22 // NW/SE bidirectional diagonal
}

// MARK: - macOS NSCursor Conversion

#if os(macOS)
import AppKit

public extension MirageCursorType {
    /// Attempt to identify the cursor type from an NSCursor instance.
    /// Returns nil for custom or unrecognized cursors.
    init?(from cursor: NSCursor?) {
        guard let cursor,
              let cursorData = cursor.image.tiffRepresentation else {
            return nil
        }

        // Use tiffRepresentation for reliable pixel-data comparison.
        // NSCursor.currentSystem returns a different object reference each time,
        // so reference comparison and NSImage.isEqual(to:) don't work reliably.
        // Comparing TIFF data ensures we match based on actual image content.

        if cursorData == NSCursor.arrow.image.tiffRepresentation { self = .arrow } else if cursorData == NSCursor.iBeam.image.tiffRepresentation {
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
        } else if #available(macOS 15.0, *) {
            if cursorData == NSCursor.frameResize(position: .topRight, directions: .inward).image.tiffRepresentation
                || cursorData == NSCursor.frameResize(position: .topRight, directions: .outward).image
                .tiffRepresentation {
                self = .resizeNorthEast
            } else if cursorData == NSCursor.frameResize(position: .topLeft, directions: .inward).image.tiffRepresentation
                || cursorData == NSCursor.frameResize(position: .topLeft, directions: .outward).image
                .tiffRepresentation {
                self = .resizeNorthWest
            } else if cursorData == NSCursor.frameResize(position: .bottomRight, directions: .inward).image
                .tiffRepresentation
                || cursorData == NSCursor.frameResize(position: .bottomRight, directions: .outward).image
                .tiffRepresentation {
                self = .resizeSouthEast
            } else if cursorData == NSCursor.frameResize(position: .bottomLeft, directions: .inward).image
                .tiffRepresentation
                || cursorData == NSCursor.frameResize(position: .bottomLeft, directions: .outward).image
                .tiffRepresentation {
                self = .resizeSouthWest
            } else if cursorData == NSCursor.frameResize(position: .topRight, directions: .all).image.tiffRepresentation
                || cursorData == NSCursor.frameResize(position: .bottomLeft, directions: .all).image
                .tiffRepresentation {
                self = .resizeNESW
            } else if cursorData == NSCursor.frameResize(position: .topLeft, directions: .all).image.tiffRepresentation
                || cursorData == NSCursor.frameResize(position: .bottomRight, directions: .all).image
                .tiffRepresentation {
                self = .resizeNWSE
            } else {
                return nil
            }
        } else {
            // Custom cursor or unrecognized system cursor
            return nil
        }
    }

    /// Get the corresponding NSCursor for this cursor type.
    var nsCursor: NSCursor {
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
        case .resizeNorthEast:
            if #available(macOS 15.0, *) {
                return .frameResize(position: .topRight, directions: .all)
            }
            return .crosshair
        case .resizeNorthWest:
            if #available(macOS 15.0, *) {
                return .frameResize(position: .topLeft, directions: .all)
            }
            return .crosshair
        case .resizeSouthEast:
            if #available(macOS 15.0, *) {
                return .frameResize(position: .bottomRight, directions: .all)
            }
            return .crosshair
        case .resizeSouthWest:
            if #available(macOS 15.0, *) {
                return .frameResize(position: .bottomLeft, directions: .all)
            }
            return .crosshair
        case .resizeNESW:
            if #available(macOS 15.0, *) {
                return .frameResize(position: .topRight, directions: .all)
            }
            return .crosshair
        case .resizeNWSE:
            if #available(macOS 15.0, *) {
                return .frameResize(position: .topLeft, directions: .all)
            }
            return .crosshair
        }
    }
}
#endif

// MARK: - iOS/iPadOS/visionOS UIPointerStyle Conversion

#if os(iOS) || os(visionOS)
import UIKit

public extension MirageCursorType {
    /// Get the appropriate UIPointerStyle for this cursor type.
    /// - Parameter region: The pointer region for context-aware styling
    /// - Returns: A UIPointerStyle that best represents this cursor type on iPadOS
    func pointerStyle(for _: UIPointerRegion) -> UIPointerStyle {
        switch self {
        case .arrow,
             .contextualMenu,
             .operationNotAllowed:
            // Default system pointer - use automatic behavior
            return UIPointerStyle.system()

        case .iBeam:
            // Text selection cursor - vertical beam
            return UIPointerStyle(shape: .verticalBeam(length: 24))

        case .crosshair:
            // Precision cursor - small plus-shaped indicator
            // iPadOS doesn't have a native crosshair, so we use a small dot
            return UIPointerStyle(shape: .roundedRect(CGRect(x: 0, y: 0, width: 8, height: 8), radius: 4))

        case .closedHand,
             .dragCopy,
             .dragLink,
             .openHand,
             .pointingHand:
            // Drag-related cursors - rely on system pointer presentation
            return UIPointerStyle.system()

        case .resizeLeft,
             .resizeLeftRight,
             .resizeRight:
            // Horizontal resize - small shape with left/right arrows
            let style = UIPointerStyle(shape: .roundedRect(CGRect(x: 0, y: 0, width: 4, height: 4), radius: 2))
            style.accessories = [.arrow(.left), .arrow(.right)]
            return style

        case .resizeDown,
             .resizeUp,
             .resizeUpDown:
            // Vertical resize - small shape with top/bottom arrows
            let style = UIPointerStyle(shape: .roundedRect(CGRect(x: 0, y: 0, width: 4, height: 4), radius: 2))
            style.accessories = [.arrow(.top), .arrow(.bottom)]
            return style

        case .resizeNESW,
             .resizeNorthEast,
             .resizeSouthWest:
            // NE/SW diagonal resize - arrows pointing topRight and bottomLeft
            let style = UIPointerStyle(shape: .roundedRect(CGRect(x: 0, y: 0, width: 4, height: 4), radius: 2))
            style.accessories = [.arrow(.topRight), .arrow(.bottomLeft)]
            return style

        case .resizeNorthWest,
             .resizeNWSE,
             .resizeSouthEast:
            // NW/SE diagonal resize - arrows pointing topLeft and bottomRight
            let style = UIPointerStyle(shape: .roundedRect(CGRect(x: 0, y: 0, width: 4, height: 4), radius: 2))
            style.accessories = [.arrow(.topLeft), .arrow(.bottomRight)]
            return style

        case .disappearingItem:
            // Dragging out of bounds - use small fading indicator
            return UIPointerStyle(shape: .roundedRect(CGRect(x: 0, y: 0, width: 16, height: 16), radius: 8))
        }
    }
}
#endif
