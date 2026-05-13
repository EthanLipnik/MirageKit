//
//  MirageInputEvent.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/2/26.
//

import CoreGraphics
import Foundation

/// Represents any input event to forward from client to host
public enum MirageInputEvent: Codable, Sendable {
    /// Key press event.
    case keyDown(MirageKeyEvent)
    /// Key release event.
    case keyUp(MirageKeyEvent)
    /// Modifier-key state change.
    case flagsChanged(MirageModifierFlags)
    /// Built-in host system action request.
    case hostSystemAction(MirageHostSystemActionRequest)
    /// Primary mouse button press.
    case mouseDown(MirageMouseEvent)
    /// Primary mouse button release.
    case mouseUp(MirageMouseEvent)
    /// Mouse movement without a pressed button.
    case mouseMoved(MirageMouseEvent)
    /// Primary-button drag.
    case mouseDragged(MirageMouseEvent)
    /// Coalesced high-frequency pointer samples.
    case pointerSampleBatch(MiragePointerSampleBatch)
    /// Secondary mouse button press.
    case rightMouseDown(MirageMouseEvent)
    /// Secondary mouse button release.
    case rightMouseUp(MirageMouseEvent)
    /// Secondary-button drag.
    case rightMouseDragged(MirageMouseEvent)
    /// Auxiliary mouse button press.
    case otherMouseDown(MirageMouseEvent)
    /// Auxiliary mouse button release.
    case otherMouseUp(MirageMouseEvent)
    /// Auxiliary-button drag.
    case otherMouseDragged(MirageMouseEvent)
    /// Scroll wheel or trackpad scroll event.
    case scrollWheel(MirageScrollEvent)
    /// Trackpad magnification gesture.
    case magnify(MirageMagnifyEvent)
    /// Trackpad rotation gesture.
    case rotate(MirageRotateEvent)
    /// Trackpad swipe gesture.
    case swipe(MirageSwipeEvent)
    /// Absolute window resize request.
    case windowResize(MirageResizeEvent)
    /// Relative window resize request.
    case relativeResize(MirageRelativeResizeEvent)
    /// Pixel-precise resize request.
    case pixelResize(MiragePixelResizeEvent)

    /// Client window received focus - host should activate the corresponding window
    case windowFocus

    /// Timestamp when the event was created (for latency measurement)
    public var timestamp: TimeInterval {
        switch self {
        case let .keyDown(e),
             let .keyUp(e): e.timestamp
        case .flagsChanged,
             .hostSystemAction,
             .windowFocus: Date.timeIntervalSinceReferenceDate
        case let .mouseDown(e),
             let .mouseDragged(e),
             let .mouseMoved(e),
             let .mouseUp(e),
             let .otherMouseDown(e),
             let .otherMouseDragged(e),
             let .otherMouseUp(e),
             let .rightMouseDown(e),
             let .rightMouseDragged(e),
             let .rightMouseUp(e):
            e.timestamp
        case let .pointerSampleBatch(e): e.timestamp
        case let .scrollWheel(e): e.timestamp
        case let .magnify(e): e.timestamp
        case let .rotate(e): e.timestamp
        case let .swipe(e): e.timestamp
        case let .windowResize(e): e.timestamp
        case let .relativeResize(e): e.timestamp
        case let .pixelResize(e): e.timestamp
        }
    }
}

/// Modifier flags for keyboard events
public struct MirageModifierFlags: OptionSet, Codable, Sendable, Hashable {
    /// Raw modifier bitmask.
    public let rawValue: UInt

    /// Creates a modifier flag set from a raw bitmask.
    ///
    /// - Parameter rawValue: Bitfield containing one or more ``MirageModifierFlags`` values.
    public init(rawValue: UInt) {
        self.rawValue = rawValue
    }

    /// Caps Lock key modifier.
    public static let capsLock = MirageModifierFlags(rawValue: 1 << 0)
    /// Shift key modifier.
    public static let shift = MirageModifierFlags(rawValue: 1 << 1)
    /// Control key modifier.
    public static let control = MirageModifierFlags(rawValue: 1 << 2)
    /// Option/Alt key modifier.
    public static let option = MirageModifierFlags(rawValue: 1 << 3)
    /// Command key modifier.
    public static let command = MirageModifierFlags(rawValue: 1 << 4)
    /// Numeric keypad modifier.
    public static let numericPad = MirageModifierFlags(rawValue: 1 << 5)
    /// Function (`Fn`) modifier.
    public static let function = MirageModifierFlags(rawValue: 1 << 6)
}

public extension MirageModifierFlags {
    /// Modifiers that participate in shortcut matching.
    static let shortcutMatchingMask: MirageModifierFlags = [.shift, .control, .option, .command]

    /// Removes state-only modifiers that should not affect shortcut identity.
    var normalizedForShortcutMatching: MirageModifierFlags {
        intersection(Self.shortcutMatchingMask)
    }
}

/// Mouse button enumeration
public enum MirageMouseButton: Int, Codable, Sendable, Hashable {
    /// Primary mouse button.
    case left = 0
    /// Secondary mouse button.
    case right = 1
    /// Middle mouse button.
    case middle = 2
    /// First auxiliary mouse button.
    case button3 = 3
    /// Fallback auxiliary mouse button for button indices greater than three.
    case button4 = 4

    /// Maps an integer button index into a canonical button enum.
    ///
    /// Values above `3` collapse to ``button4``.
    ///
    /// - Parameter buttonNumber: Input device button number.
    public init(buttonNumber: Int) {
        switch buttonNumber {
        case 0: self = .left
        case 1: self = .right
        case 2: self = .middle
        case 3: self = .button3
        default: self = .button4
        }
    }
}

/// Scroll phase for trackpad gestures
public enum MirageScrollPhase: Int, Codable, Sendable {
    /// No active scroll phase.
    case none = 0
    /// Scroll gesture began.
    case began = 1
    /// Scroll gesture changed.
    case changed = 2
    /// Scroll gesture ended.
    case ended = 3
    /// Scroll gesture cancelled.
    case cancelled = 4
    /// Scroll gesture may begin.
    case mayBegin = 5
}
