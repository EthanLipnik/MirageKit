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
