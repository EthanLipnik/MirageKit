//
//  MirageCursorType.swift
//  MirageWire
//
//  Created by Ethan Lipnik on 6/5/26.
//

/// Stable cursor identities synchronized between host and client.
public enum MirageCursorType: Int, Codable, Sendable, Hashable {
    /// Default pointer.
    case arrow = 0
    /// Text selection cursor.
    case iBeam = 1
    /// Precision selection cursor.
    case crosshair = 2
    /// Grabbed or dragging hand cursor.
    case closedHand = 3
    /// Ready-to-grab hand cursor.
    case openHand = 4
    /// Link or clickable-element cursor.
    case pointingHand = 5
    /// Left-edge resize cursor.
    case resizeLeft = 6
    /// Right-edge resize cursor.
    case resizeRight = 7
    /// Horizontal bidirectional resize cursor.
    case resizeLeftRight = 8
    /// Top-edge resize cursor.
    case resizeUp = 9
    /// Bottom-edge resize cursor.
    case resizeDown = 10
    /// Vertical bidirectional resize cursor.
    case resizeUpDown = 11
    /// Cursor used while dragging an item out of a valid destination.
    case disappearingItem = 12
    /// Cursor for forbidden or unavailable actions.
    case operationNotAllowed = 13
    /// Cursor used while dragging a link.
    case dragLink = 14
    /// Cursor used while dragging with copy semantics.
    case dragCopy = 15
    /// Cursor indicating a contextual menu is available.
    case contextualMenu = 16
    /// Northeast corner resize cursor.
    case resizeNorthEast = 17
    /// Northwest corner resize cursor.
    case resizeNorthWest = 18
    /// Southeast corner resize cursor.
    case resizeSouthEast = 19
    /// Southwest corner resize cursor.
    case resizeSouthWest = 20
    /// Northeast/southwest bidirectional diagonal resize cursor.
    case resizeNESW = 21
    /// Northwest/southeast bidirectional diagonal resize cursor.
    case resizeNWSE = 22
}
