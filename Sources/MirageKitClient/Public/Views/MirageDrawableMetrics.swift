//
//  MirageDrawableMetrics.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/23/26.
//
//  Drawable metrics used for resize handling without screen polling.
//

import CoreGraphics
import MirageKit

public struct MirageDrawableMetrics: Sendable, Equatable {
    public let pixelSize: CGSize
    public let viewSize: CGSize
    public let scaleFactor: CGFloat
    public let screenPointSize: CGSize?
    public let screenScale: CGFloat?
    public let screenNativePixelSize: CGSize?
    public let screenNativeScale: CGFloat?

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

    static func shouldReportChange(
        from previous: MirageDrawableMetrics?,
        to next: MirageDrawableMetrics
    )
    -> Bool {
        previous != next
    }
}
