//
//  CGVirtualDisplayBridge+WindowSpace.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Window space management bridge.
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
#if os(macOS)
import ColorSync
import CoreGraphics
import Foundation

// MARK: - Window Space Management Bridge

/// Bridge to private CGS window/space management APIs
enum CGSWindowSpaceBridge {
    // MARK: - Private Type Aliases

    private typealias CGSConnectionID = UInt32

    private struct CGSSpaceMask: OptionSet {
        let rawValue: UInt32
        static let all = CGSSpaceMask(rawValue: 1 << 2)
    }

    // MARK: - Private Function Declarations

    @_silgen_name("CGSMainConnectionID")
    private static func CGSMainConnectionID() -> CGSConnectionID

    @_silgen_name("CGSAddWindowsToSpaces")
    private static func CGSAddWindowsToSpaces(
        _ _: CGSConnectionID,
        _ _: CFArray,
        _ _: CFArray
    )

    @_silgen_name("CGSRemoveWindowsFromSpaces")
    private static func CGSRemoveWindowsFromSpaces(
        _ _: CGSConnectionID,
        _ _: CFArray,
        _ _: CFArray
    )

    @_silgen_name("CGSCopySpacesForWindows")
    private static func CGSCopySpacesForWindows(
        _ _: CGSConnectionID,
        _ _: UInt32,
        _ _: CFArray
    )
        -> CFArray?

    @_silgen_name("CGSManagedDisplayGetCurrentSpace")
    private static func CGSManagedDisplayGetCurrentSpace(
        _ _: CGSConnectionID,
        _ _: CFString
    )
        -> CGSSpaceID

    @_silgen_name("CGSManagedDisplaySetCurrentSpace")
    private static func CGSManagedDisplaySetCurrentSpace(
        _ _: CGSConnectionID,
        _ _: CFString,
        _ _: CGSSpaceID
    )
        -> CGError

    @_silgen_name("CGSMoveWindow")
    private static func CGSMoveWindow(
        _ _: CGSConnectionID,
        _ _: CGWindowID,
        _ _: UnsafePointer<CGPoint>
    )
        -> CGError

    /// Order window relative to other windows
    /// place: 1 = above, -1 = below, 0 = out (hide)
    @_silgen_name("CGSOrderWindow")
    private static func CGSOrderWindow(
        _ _: CGSConnectionID,
        _ _: CGWindowID,
        _ _: Int32,
        _ _: CGWindowID
    )
        -> CGError

    // MARK: - Public Interface

    static var connectionID: UInt32 {
        CGSMainConnectionID()
    }

    static func spaces(for windowID: CGWindowID) -> [CGSSpaceID] {
        let connection = connectionID
        let windowArray = [windowID] as CFArray

        guard let spacesArray = CGSCopySpacesForWindows(connection, CGSSpaceMask.all.rawValue, windowArray) else { return [] }

        var spaces: [CGSSpaceID] = []
        for i in 0 ..< CFArrayGetCount(spacesArray) {
            if let spacePtr = CFArrayGetValueAtIndex(spacesArray, i) {
                let value = unsafeBitCast(spacePtr, to: CFTypeRef.self)
                if CFGetTypeID(value) == CFNumberGetTypeID() {
                    var numericSpaceID: Int64 = 0
                    if CFNumberGetValue(
                        unsafeDowncast(value, to: CFNumber.self),
                        .sInt64Type,
                        &numericSpaceID
                    ) {
                        spaces.append(UInt64(numericSpaceID))
                        continue
                    }
                }

                // Fallback for hosts that expose raw pointer-encoded IDs.
                let pointerEncoded = UInt64(bitPattern: Int64(Int(bitPattern: spacePtr)))
                spaces.append(pointerEncoded)
            }
        }

        // Keep deterministic ordering and remove accidental duplicates.
        return Array(Set(spaces)).sorted()
    }

    static func currentSpace(for displayID: CGDirectDisplayID) -> CGSSpaceID {
        let connection = connectionID
        guard let uuid = displayUUID(for: displayID) else {
            MirageLogger.host("Cannot get current space: no valid UUID for display \(displayID)")
            return 0
        }
        return CGSManagedDisplayGetCurrentSpace(connection, uuid as CFString)
    }

    static func setCurrentSpaceForDisplay(_ displayID: CGDirectDisplayID, spaceID: CGSSpaceID) -> Bool {
        let connection = connectionID
        guard let uuid = displayUUID(for: displayID) else {
            MirageLogger.host("Cannot set current space: no valid UUID for display \(displayID)")
            return false
        }
        let result = CGSManagedDisplaySetCurrentSpace(connection, uuid as CFString, spaceID)
        return result == .success
    }

    static func moveWindowToSpace(_ windowID: CGWindowID, spaceID: CGSSpaceID) {
        let connection = connectionID
        let windowArray = [windowID] as CFArray
        let spaceArray = [spaceID] as CFArray

        // Remove from current spaces first
        let currentSpaces = spaces(for: windowID)
        if !currentSpaces.isEmpty {
            let currentSpacesArray = currentSpaces as CFArray
            CGSRemoveWindowsFromSpaces(connection, windowArray, currentSpacesArray)
        }

        CGSAddWindowsToSpaces(connection, windowArray, spaceArray)
        MirageLogger.host("Moved window \(windowID) to space \(spaceID)")
    }

    static func moveWindow(_ windowID: CGWindowID, to point: CGPoint) -> Bool {
        let connection = connectionID
        var mutablePoint = point
        let result = CGSMoveWindow(connection, windowID, &mutablePoint)
        return result == .success
    }

    /// Bring a window to the front using SkyLight APIs
    /// This works even on virtual displays where AXUIElement fails
    /// - Parameter windowID: The CGWindowID to bring to front
    /// - Returns: true if successful
    static func bringWindowToFront(_ windowID: CGWindowID) -> Bool {
        let connection = connectionID
        // place = 1 means "above", relativeToWindow = 0 means "above all"
        let result = CGSOrderWindow(connection, windowID, 1, 0)
        return result == .success
    }

    static func bringWindowToFrontIfPossible(_ windowID: CGWindowID) {
        let connection = connectionID
        let result = CGSOrderWindow(connection, windowID, 1, 0)
        guard result != .success else { return }
    }

    private static func displayUUID(for displayID: CGDirectDisplayID) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else {
            return nil
        }
        return CFUUIDCreateString(nil, uuid) as String
    }
}
#endif
