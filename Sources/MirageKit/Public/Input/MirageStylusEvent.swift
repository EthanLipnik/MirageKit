//
//  MirageStylusEvent.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/9/26.
//
//  Stylus orientation and hover metadata for tablet-style input injection.
//

import CoreGraphics
import Foundation

/// Stylus metadata attached to pointer events.
public struct MirageStylusEvent: Codable, Sendable, Hashable {
    /// Altitude angle in radians (0 = parallel to the surface, pi/2 = perpendicular).
    public let altitudeAngle: CGFloat

    /// Azimuth angle in radians, in the client view coordinate space.
    public let azimuthAngle: CGFloat

    /// Horizontal tilt component, normalized to -1...1.
    public let tiltX: CGFloat

    /// Vertical tilt component, normalized to -1...1.
    public let tiltY: CGFloat

    /// Optional roll angle in radians for pencils that support barrel roll.
    public let rollAngle: CGFloat?

    /// Optional normalized hover height, where 1 is farthest from the surface.
    public let zOffset: CGFloat?

    /// Whether this metadata represents a hover sample instead of contact.
    public let isHovering: Bool

    /// Creates stylus metadata for pointer injection.
    ///
    /// - Parameters:
    ///   - altitudeAngle: Pen altitude in radians (`0` parallel, `pi/2` perpendicular).
    ///   - azimuthAngle: Pen azimuth in client-space radians.
    ///   - tiltX: Horizontal tilt component.
    ///   - tiltY: Vertical tilt component.
    ///   - rollAngle: Optional barrel roll in radians.
    ///   - zOffset: Optional normalized hover distance.
    ///   - isHovering: Whether sample was captured while hovering.
    public init(
        altitudeAngle: CGFloat,
        azimuthAngle: CGFloat,
        tiltX: CGFloat,
        tiltY: CGFloat,
        rollAngle: CGFloat? = nil,
        zOffset: CGFloat? = nil,
        isHovering: Bool = false
    ) {
        self.altitudeAngle = altitudeAngle
        self.azimuthAngle = azimuthAngle
        self.tiltX = tiltX
        self.tiltY = tiltY
        self.rollAngle = rollAngle
        self.zOffset = zOffset
        self.isHovering = isHovering
    }
}
