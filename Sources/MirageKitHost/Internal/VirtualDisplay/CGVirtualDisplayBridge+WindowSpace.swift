//
//  CGVirtualDisplayBridge+WindowSpace.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Window space management bridge.
//

import MirageKit
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
        _ connection: CGSConnectionID,
        _ windows: CFArray,
        _ spaces: CFArray
    )

    @_silgen_name("CGSRemoveWindowsFromSpaces")
    private static func CGSRemoveWindowsFromSpaces(
        _ connection: CGSConnectionID,
        _ windows: CFArray,
        _ spaces: CFArray
    )

    @_silgen_name("CGSCopySpacesForWindows")
    private static func CGSCopySpacesForWindows(
        _ connection: CGSConnectionID,
        _ mask: UInt32,
        _ windows: CFArray
    )
        -> CFArray?

    @_silgen_name("CGSManagedDisplayGetCurrentSpace")
    private static func CGSManagedDisplayGetCurrentSpace(
        _ connection: CGSConnectionID,
        _ displayUUID: CFString
    )
        -> CGSSpaceID

    @_silgen_name("CGSManagedDisplaySetCurrentSpace")
    private static func CGSManagedDisplaySetCurrentSpace(
        _ connection: CGSConnectionID,
        _ displayUUID: CFString,
        _ spaceID: CGSSpaceID
    )
        -> CGError

    @_silgen_name("CGSMoveWindow")
    private static func CGSMoveWindow(
        _ connection: CGSConnectionID,
        _ window: CGWindowID,
        _ point: UnsafePointer<CGPoint>
    )
        -> CGError

    /// Order window relative to other windows
    /// place: 1 = above, -1 = below, 0 = out (hide)
    @_silgen_name("CGSOrderWindow")
    private static func CGSOrderWindow(
        _ connection: CGSConnectionID,
        _ window: CGWindowID,
        _ place: Int32,
        _ relativeToWindow: CGWindowID
    )
        -> CGError

    /// Set window level (like always-on-top)
    @_silgen_name("CGSSetWindowLevel")
    private static func CGSSetWindowLevel(
        _ connection: CGSConnectionID,
        _ window: CGWindowID,
        _ level: Int32
    )
        -> CGError

    // MARK: - Public Interface

    static func getConnectionID() -> UInt32 {
        CGSMainConnectionID()
    }

    static func getSpacesForWindow(_ windowID: CGWindowID) -> [CGSSpaceID] {
        let connection = getConnectionID()
        let windowArray = [windowID] as CFArray

        guard let spacesArray = CGSCopySpacesForWindows(connection, CGSSpaceMask.all.rawValue, windowArray) else { return [] }

        var spaces: [CGSSpaceID] = []
        for i in 0 ..< CFArrayGetCount(spacesArray) {
            if let spacePtr = CFArrayGetValueAtIndex(spacesArray, i) {
                let spaceID = UInt64(bitPattern: Int64(Int(bitPattern: spacePtr)))
                spaces.append(spaceID)
            }
        }

        return spaces
    }

    static func getCurrentSpaceForDisplay(_ displayID: CGDirectDisplayID) -> CGSSpaceID {
        let connection = getConnectionID()
        let uuid = getDisplayUUID(displayID)
        return CGSManagedDisplayGetCurrentSpace(connection, uuid as CFString)
    }

    static func setCurrentSpaceForDisplay(_ displayID: CGDirectDisplayID, spaceID: CGSSpaceID) -> Bool {
        let connection = getConnectionID()
        let uuid = getDisplayUUID(displayID)
        let result = CGSManagedDisplaySetCurrentSpace(connection, uuid as CFString, spaceID)
        return result == .success
    }

    static func moveWindowToSpace(_ windowID: CGWindowID, spaceID: CGSSpaceID) {
        let connection = getConnectionID()
        let windowArray = [windowID] as CFArray
        let spaceArray = [spaceID] as CFArray

        // Remove from current spaces first
        let currentSpaces = getSpacesForWindow(windowID)
        if !currentSpaces.isEmpty {
            let currentSpacesArray = currentSpaces as CFArray
            CGSRemoveWindowsFromSpaces(connection, windowArray, currentSpacesArray)
        }

        CGSAddWindowsToSpaces(connection, windowArray, spaceArray)
        MirageLogger.host("Moved window \(windowID) to space \(spaceID)")
    }

    static func moveWindow(_ windowID: CGWindowID, to point: CGPoint) -> Bool {
        let connection = getConnectionID()
        var mutablePoint = point
        let result = CGSMoveWindow(connection, windowID, &mutablePoint)
        return result == .success
    }

    /// Bring a window to the front using SkyLight APIs
    /// This works even on virtual displays where AXUIElement fails
    /// - Parameter windowID: The CGWindowID to bring to front
    /// - Returns: true if successful
    static func bringWindowToFront(_ windowID: CGWindowID) -> Bool {
        let connection = getConnectionID()
        // place = 1 means "above", relativeToWindow = 0 means "above all"
        let result = CGSOrderWindow(connection, windowID, 1, 0)
        return result == .success
    }

    private static func getDisplayUUID(_ displayID: CGDirectDisplayID) -> String {
        if let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() { return CFUUIDCreateString(nil, uuid) as String }
        return String(displayID)
    }
}
#endif
