//
//  MirageKeyEvent.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/2/26.
//

import Foundation

/// Represents a keyboard event
public struct MirageKeyEvent: Codable, Sendable, Hashable {
    /// Virtual key code
    public let keyCode: UInt16

    /// Characters produced by the key (with modifiers)
    public let characters: String?

    /// Characters ignoring modifiers
    public let charactersIgnoringModifiers: String?

    /// Active modifier flags
    public let modifiers: MirageModifierFlags

    /// Whether this is a key repeat
    public let isRepeat: Bool

    /// Event timestamp
    public let timestamp: TimeInterval

    /// Creates a keyboard event payload.
    ///
    /// - Parameters:
    ///   - keyCode: Platform key code in macOS virtual key space.
    ///   - characters: Text produced with active modifiers applied.
    ///   - charactersIgnoringModifiers: Text produced without modifier transformation.
    ///   - modifiers: Active modifier flags at event time.
    ///   - isRepeat: Whether this event comes from key-repeat behavior.
    ///   - timestamp: Event creation time.
    public init(
        keyCode: UInt16,
        characters: String? = nil,
        charactersIgnoringModifiers: String? = nil,
        modifiers: MirageModifierFlags = [],
        isRepeat: Bool = false,
        timestamp: TimeInterval = Date.timeIntervalSinceReferenceDate
    ) {
        self.keyCode = keyCode
        self.characters = characters
        self.charactersIgnoringModifiers = charactersIgnoringModifiers
        self.modifiers = modifiers
        self.isRepeat = isRepeat
        self.timestamp = timestamp
    }
}
