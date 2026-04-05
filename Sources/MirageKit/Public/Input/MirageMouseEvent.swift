//
//  MirageMouseEvent.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/2/26.
//

import CoreGraphics
import Foundation

/// Represents a mouse event
public struct MirageMouseEvent: Codable, Sendable, Hashable {
    /// Mouse button involved
    public let button: MirageMouseButton

    /// Location in normalized stream coordinates.
    /// Secondary desktop cursor-lock input may temporarily exceed `0...1`
    /// while the host cursor travels onto another display.
    public let location: CGPoint

    /// Click count for multi-click detection
    public let clickCount: Int

    /// Active modifier flags
    public let modifiers: MirageModifierFlags

    /// Pressure for Force Touch (0.0 - 1.0)
    public let pressure: CGFloat

    /// Optional stylus metadata for tablet-style input.
    public let stylus: MirageStylusEvent?

    /// Event timestamp
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

/// Represents a scroll wheel event
public struct MirageScrollEvent: Codable, Sendable, Hashable {
    /// Horizontal scroll delta
    public let deltaX: CGFloat

    /// Vertical scroll delta
    public let deltaY: CGFloat

    /// Location in normalized stream coordinates.
    /// Secondary desktop cursor-lock input may temporarily exceed `0...1`.
    /// Used to inject scroll at cursor position rather than window center.
    public let location: CGPoint?

    /// Scroll phase (for trackpad gestures)
    public let phase: MirageScrollPhase

    /// Momentum phase (for inertial scrolling)
    public let momentumPhase: MirageScrollPhase

    /// Active modifier flags
    public let modifiers: MirageModifierFlags

    /// Whether this is a precise scroll (trackpad vs mouse wheel)
    public let isPrecise: Bool

    /// Event timestamp
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

/// Represents a magnification gesture event
public struct MirageMagnifyEvent: Codable, Sendable, Hashable {
    /// Magnification delta
    public let magnification: CGFloat

    /// Gesture phase
    public let phase: MirageScrollPhase

    /// Event timestamp
    public let timestamp: TimeInterval

    /// Creates a magnify gesture event.
    ///
    /// - Parameters:
    ///   - magnification: Scale delta, where positive values zoom in.
    ///   - phase: Gesture lifecycle phase.
    ///   - timestamp: Event creation time.
    public init(
        magnification: CGFloat,
        phase: MirageScrollPhase = .none,
        timestamp: TimeInterval = Date.timeIntervalSinceReferenceDate
    ) {
        self.magnification = magnification
        self.phase = phase
        self.timestamp = timestamp
    }
}

/// Represents a rotation gesture event
public struct MirageRotateEvent: Codable, Sendable, Hashable {
    /// Rotation in degrees
    public let rotation: CGFloat

    /// Gesture phase
    public let phase: MirageScrollPhase

    /// Event timestamp
    public let timestamp: TimeInterval

    /// Creates a rotate gesture event.
    ///
    /// - Parameters:
    ///   - rotation: Rotation delta in degrees.
    ///   - phase: Gesture lifecycle phase.
    ///   - timestamp: Event creation time.
    public init(
        rotation: CGFloat,
        phase: MirageScrollPhase = .none,
        timestamp: TimeInterval = Date.timeIntervalSinceReferenceDate
    ) {
        self.rotation = rotation
        self.phase = phase
        self.timestamp = timestamp
    }
}

/// Represents a window resize request from client using point size + scale.
public struct MirageResizeEvent: Codable, Sendable, Hashable {
    /// Target window ID
    public let windowID: WindowID

    /// New requested size in points (used to resize Mac window)
    public let newSize: CGSize

    /// Client's display scale factor (e.g., 2.0 for Retina, ~1.72 for iPad)
    public let scaleFactor: CGFloat

    /// Actual pixel dimensions the client needs (newSize × scaleFactor)
    /// The host should encode at this resolution for 1:1 pixel mapping
    public let pixelSize: CGSize

    /// Event timestamp
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

/// Represents a relative window sizing request from client
/// Host uses aspect ratio and pixel dimensions to calculate optimal window size
public struct MirageRelativeResizeEvent: Codable, Sendable, Hashable {
    /// Target window ID
    public let windowID: WindowID

    /// Desired aspect ratio (width / height, e.g., 1.333 for 4:3)
    public let aspectRatio: CGFloat

    /// Relative scale as percentage of screen area (0.0 - 1.0)
    /// Example: 0.25 = window should occupy 25% of host screen area
    public let relativeScale: CGFloat

    /// Client's screen dimensions in points (for reference/debugging only)
    public let clientScreenSize: CGSize

    /// Client's drawable pixel width - host should produce this exact resolution
    public let pixelWidth: Int

    /// Client's drawable pixel height - host should produce this exact resolution
    public let pixelHeight: Int

    /// Event timestamp
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

/// Represents an absolute pixel-based resize request from client
/// Host resizes window so that: window_points × host_scale = client_pixels
/// This ensures 1:1 pixel matching for maximum quality
public struct MiragePixelResizeEvent: Codable, Sendable, Hashable {
    /// Target window ID
    public let windowID: WindowID

    /// Exact drawable pixel width the client needs
    public let pixelWidth: Int

    /// Exact drawable pixel height the client needs
    public let pixelHeight: Int

    /// Event timestamp
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
