//
//  MirageDrawableMetrics.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/23/26.
//
//  Drawable metrics used for resize handling without screen polling.
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
import CoreGraphics

/// Current drawable, view, and screen metrics used to drive stream resize decisions.
public struct MirageDrawableMetrics: Sendable, Equatable {
    /// Backing drawable size in pixels.
    public let pixelSize: CGSize
    /// Stream view size in points.
    public let viewSize: CGSize
    /// Effective backing scale used to derive ``pixelSize`` from ``viewSize``.
    public let scaleFactor: CGFloat
    /// Current screen size in points when available.
    public let screenPointSize: CGSize?
    /// Current screen scale when available.
    public let screenScale: CGFloat?
    /// Native screen pixel size when available.
    public let screenNativePixelSize: CGSize?
    /// Native screen scale when available.
    public let screenNativeScale: CGFloat?

    /// Creates a drawable metrics snapshot.
    public init(
        pixelSize: CGSize,
        viewSize: CGSize,
        scaleFactor: CGFloat,
        screenPointSize: CGSize? = nil,
        screenScale: CGFloat? = nil,
        screenNativePixelSize: CGSize? = nil,
        screenNativeScale: CGFloat? = nil
    ) {
        self.pixelSize = pixelSize
        self.viewSize = viewSize
        self.scaleFactor = scaleFactor
        self.screenPointSize = screenPointSize
        self.screenScale = screenScale
        self.screenNativePixelSize = screenNativePixelSize
        self.screenNativeScale = screenNativeScale
    }
}
