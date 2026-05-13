//
//  MirageMouseEvent.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/2/26.
//

import CoreGraphics
import Foundation

/// Pointer button or movement event forwarded from the client to the host.
public struct MirageMouseEvent: Codable, Sendable, Hashable {
    /// Mouse button involved in the event.
    public let button: MirageMouseButton

    /// Location in normalized stream coordinates.
    /// Secondary desktop cursor-lock input may temporarily exceed `0...1`
    /// while the host cursor travels onto another display.
    public let location: CGPoint

    /// Click count for multi-click detection.
    public let clickCount: Int

    /// Active modifier flags.
    public let modifiers: MirageModifierFlags

    /// Pressure for Force Touch or stylus contact, normalized to `0...1`.
    public let pressure: CGFloat

    /// Optional stylus metadata for tablet-style input.
    public let stylus: MirageStylusEvent?

    /// Event creation timestamp.
    public let timestamp: TimeInterval

    /// Creates a pointer event.
    ///
    /// - Parameters:
    ///   - button: Logical button associated with the event.
    ///   - location: Normalized coordinates in host stream space.
    ///     Secondary desktop cursor-lock input may temporarily exceed `0...1`.
    ///   - clickCount: Click sequence count for multi-click interactions.
    ///   - modifiers: Active keyboard modifiers.
    ///   - pressure: Pressure scalar used by force/stylus paths.
    ///   - stylus: Optional stylus orientation data for tablet-aware apps.
    ///   - timestamp: Event creation time.
    public init(
        button: MirageMouseButton = .left,
        location: CGPoint,
        clickCount: Int = 1,
        modifiers: MirageModifierFlags = [],
        pressure: CGFloat = 1.0,
        stylus: MirageStylusEvent? = nil,
        timestamp: TimeInterval = Date.timeIntervalSinceReferenceDate
    ) {
        self.button = button
        self.location = location
        self.clickCount = clickCount
        self.modifiers = modifiers
        self.pressure = pressure
        self.stylus = stylus
        self.timestamp = timestamp
    }
}

/// Scroll wheel or trackpad scroll event.
public struct MirageScrollEvent: Codable, Sendable, Hashable {
    /// Horizontal scroll delta.
    public let deltaX: CGFloat

    /// Vertical scroll delta.
    public let deltaY: CGFloat

    /// Location in normalized stream coordinates.
    /// Secondary desktop cursor-lock input may temporarily exceed `0...1`.
    /// Used to inject scroll at cursor position rather than window center.
    public let location: CGPoint?

    /// Physical scroll phase for trackpad gestures.
    public let phase: MirageScrollPhase

    /// Momentum phase for inertial scrolling.
    public let momentumPhase: MirageScrollPhase

    /// Active modifier flags.
    public let modifiers: MirageModifierFlags

    /// Whether this is high-resolution trackpad-style scrolling.
    public let isPrecise: Bool

    /// Event creation timestamp.
    public let timestamp: TimeInterval

    /// Creates a scroll event.
    ///
    /// - Parameters:
    ///   - deltaX: Horizontal scroll delta.
    ///   - deltaY: Vertical scroll delta.
    ///   - location: Optional cursor location where scroll should be injected.
    ///   - phase: Gesture phase for physical scroll.
    ///   - momentumPhase: Gesture phase for momentum/inertial scroll.
    ///   - modifiers: Active keyboard modifiers.
    ///   - isPrecise: Indicates trackpad/high-resolution scroll input.
    ///   - timestamp: Event creation time.
    public init(
        deltaX: CGFloat,
        deltaY: CGFloat,
        location: CGPoint? = nil,
        phase: MirageScrollPhase = .none,
        momentumPhase: MirageScrollPhase = .none,
        modifiers: MirageModifierFlags = [],
        isPrecise: Bool = false,
        timestamp: TimeInterval = Date.timeIntervalSinceReferenceDate
    ) {
        self.deltaX = deltaX
        self.deltaY = deltaY
        self.location = location
        self.phase = phase
        self.momentumPhase = momentumPhase
        self.modifiers = modifiers
        self.isPrecise = isPrecise
        self.timestamp = timestamp
    }
}

/// Trackpad magnification gesture event.
public struct MirageMagnifyEvent: Codable, Sendable, Hashable {
    /// Magnification delta, where positive values zoom in.
    public let magnification: CGFloat

    /// Location in normalized stream coordinates.
    public let location: CGPoint?

    /// Gesture lifecycle phase.
    public let phase: MirageScrollPhase

    /// Active modifier flags.
    public let modifiers: MirageModifierFlags

    /// Event creation timestamp.
    public let timestamp: TimeInterval

    /// Creates a magnify gesture event.
    ///
    /// - Parameters:
    ///   - magnification: Scale delta, where positive values zoom in.
    ///   - location: Optional normalized cursor/contact location.
    ///   - phase: Gesture lifecycle phase.
    ///   - modifiers: Active keyboard modifiers.
    ///   - timestamp: Event creation time.
    public init(
        magnification: CGFloat,
        location: CGPoint? = nil,
        phase: MirageScrollPhase = .none,
        modifiers: MirageModifierFlags = [],
        timestamp: TimeInterval = Date.timeIntervalSinceReferenceDate
    ) {
        self.magnification = magnification
        self.location = location
        self.phase = phase
        self.modifiers = modifiers
        self.timestamp = timestamp
    }
}

/// Trackpad rotation gesture event.
public struct MirageRotateEvent: Codable, Sendable, Hashable {
    /// Rotation delta in degrees.
    public let rotation: CGFloat

    /// Location in normalized stream coordinates.
    public let location: CGPoint?

    /// Gesture lifecycle phase.
    public let phase: MirageScrollPhase

    /// Active modifier flags.
    public let modifiers: MirageModifierFlags

    /// Event creation timestamp.
    public let timestamp: TimeInterval

    /// Creates a rotate gesture event.
    ///
    /// - Parameters:
    ///   - rotation: Rotation delta in degrees.
    ///   - location: Optional normalized cursor/contact location.
    ///   - phase: Gesture lifecycle phase.
    ///   - modifiers: Active keyboard modifiers.
    ///   - timestamp: Event creation time.
    public init(
        rotation: CGFloat,
        location: CGPoint? = nil,
        phase: MirageScrollPhase = .none,
        modifiers: MirageModifierFlags = [],
        timestamp: TimeInterval = Date.timeIntervalSinceReferenceDate
    ) {
        self.rotation = rotation
        self.location = location
        self.phase = phase
        self.modifiers = modifiers
        self.timestamp = timestamp
    }
}

/// Represents a trackpad swipe gesture event.
public struct MirageSwipeEvent: Codable, Sendable, Hashable {
    /// Horizontal swipe delta in points or event units.
    public let deltaX: CGFloat

    /// Vertical swipe delta in points or event units.
    public let deltaY: CGFloat

    /// Location in normalized stream coordinates.
    public let location: CGPoint?

    /// Gesture phase.
    public let phase: MirageScrollPhase

    /// Active modifier flags.
    public let modifiers: MirageModifierFlags

    /// Event timestamp.
    public let timestamp: TimeInterval

    /// Creates a trackpad swipe gesture event.
    ///
    /// - Parameters:
    ///   - deltaX: Horizontal swipe delta.
    ///   - deltaY: Vertical swipe delta.
    ///   - location: Optional normalized cursor/contact location.
    ///   - phase: Gesture lifecycle phase.
    ///   - modifiers: Active keyboard modifiers.
    ///   - timestamp: Event creation time.
    public init(
        deltaX: CGFloat,
        deltaY: CGFloat,
        location: CGPoint? = nil,
        phase: MirageScrollPhase = .none,
        modifiers: MirageModifierFlags = [],
        timestamp: TimeInterval = Date.timeIntervalSinceReferenceDate
    ) {
        self.deltaX = deltaX
        self.deltaY = deltaY
        self.location = location
        self.phase = phase
        self.modifiers = modifiers
        self.timestamp = timestamp
    }
}

/// Window resize request expressed as point size plus client display scale.
public struct MirageResizeEvent: Codable, Sendable, Hashable {
    /// Target window identifier.
    public let windowID: WindowID

    /// Requested host window size in points.
    public let newSize: CGSize

    /// Client display scale factor.
    public let scaleFactor: CGFloat

    /// Pixel dimensions the client needs for 1:1 stream mapping.
    public let pixelSize: CGSize

    /// Event creation timestamp.
    public let timestamp: TimeInterval

    /// Creates a resize event from point size plus client scale.
    ///
    /// - Parameters:
    ///   - windowID: Target window identifier.
    ///   - newSize: Desired host window size in points.
    ///   - scaleFactor: Client display scale used to derive exact pixel size.
    ///   - timestamp: Event creation time.
    ///
    /// - Note: Prefer ``MiragePixelResizeEvent`` for exact pixel contracts.
    public init(
        windowID: WindowID,
        newSize: CGSize,
        scaleFactor: CGFloat = 2.0,
        timestamp: TimeInterval = Date.timeIntervalSinceReferenceDate
    ) {
        self.windowID = windowID
        self.newSize = newSize
        self.scaleFactor = scaleFactor
        pixelSize = CGSize(
            width: newSize.width * scaleFactor,
            height: newSize.height * scaleFactor
        )
        self.timestamp = timestamp
    }
}

/// Relative window sizing request based on client display shape and target area.
public struct MirageRelativeResizeEvent: Codable, Sendable, Hashable {
    /// Target window identifier.
    public let windowID: WindowID

    /// Desired width-to-height ratio.
    public let aspectRatio: CGFloat

    /// Relative target area usage, clamped to `0.01...1.0`.
    public let relativeScale: CGFloat

    /// Client screen dimensions in points for reference and diagnostics.
    public let clientScreenSize: CGSize

    /// Exact drawable pixel width requested by the client.
    public let pixelWidth: Int

    /// Exact drawable pixel height requested by the client.
    public let pixelHeight: Int

    /// Event creation timestamp.
    public let timestamp: TimeInterval

    /// Creates a relative resize event.
    ///
    /// - Parameters:
    ///   - windowID: Target window identifier.
    ///   - aspectRatio: Desired width-to-height ratio.
    ///   - relativeScale: Relative target area usage (`0.01...1.0` after clamping).
    ///   - clientScreenSize: Client screen size in points.
    ///   - pixelWidth: Exact requested encoded pixel width.
    ///   - pixelHeight: Exact requested encoded pixel height.
    ///   - timestamp: Event creation time.
    public init(
        windowID: WindowID,
        aspectRatio: CGFloat,
        relativeScale: CGFloat,
        clientScreenSize: CGSize,
        pixelWidth: Int = 0,
        pixelHeight: Int = 0,
        timestamp: TimeInterval = Date.timeIntervalSinceReferenceDate
    ) {
        self.windowID = windowID
        self.aspectRatio = aspectRatio
        self.relativeScale = min(1.0, max(0.01, relativeScale))
        self.clientScreenSize = clientScreenSize
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.timestamp = timestamp
    }
}

/// Absolute pixel-based resize request from the client.
public struct MiragePixelResizeEvent: Codable, Sendable, Hashable {
    /// Target window identifier.
    public let windowID: WindowID

    /// Exact drawable pixel width requested by the client.
    public let pixelWidth: Int

    /// Exact drawable pixel height requested by the client.
    public let pixelHeight: Int

    /// Event creation timestamp.
    public let timestamp: TimeInterval

    /// Creates a pixel-accurate resize event.
    ///
    /// - Parameters:
    ///   - windowID: Target window identifier.
    ///   - pixelWidth: Exact requested pixel width.
    ///   - pixelHeight: Exact requested pixel height.
    ///   - timestamp: Event creation time.
    public init(
        windowID: WindowID,
        pixelWidth: Int,
        pixelHeight: Int,
        timestamp: TimeInterval = Date.timeIntervalSinceReferenceDate
    ) {
        self.windowID = windowID
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.timestamp = timestamp
    }
}
