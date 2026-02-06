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

    /// Location in normalized coordinates (0-1 within window)
    public let location: CGPoint

    /// Click count for multi-click detection
    public let clickCount: Int

    /// Active modifier flags
    public let modifiers: MirageModifierFlags

    /// Pressure for Force Touch (0.0 - 1.0)
    public let pressure: CGFloat

    /// Event timestamp
    public let timestamp: TimeInterval

    public init(
        button: MirageMouseButton = .left,
        location: CGPoint,
        clickCount: Int = 1,
        modifiers: MirageModifierFlags = [],
        pressure: CGFloat = 1.0,
        timestamp: TimeInterval = Date.timeIntervalSinceReferenceDate
    ) {
        self.button = button
        self.location = location
        self.clickCount = clickCount
        self.modifiers = modifiers
        self.pressure = pressure
        self.timestamp = timestamp
    }
}

/// Represents a scroll wheel event
public struct MirageScrollEvent: Codable, Sendable, Hashable {
    /// Horizontal scroll delta
    public let deltaX: CGFloat

    /// Vertical scroll delta
    public let deltaY: CGFloat

    /// Location in normalized coordinates (0-1 within window)
    /// Used to inject scroll at cursor position rather than window center
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

/// Represents a window resize request from client (legacy - uses absolute pixel dimensions)
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
