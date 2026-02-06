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

    public init(pixelSize: CGSize, viewSize: CGSize, scaleFactor: CGFloat) {
        self.pixelSize = pixelSize
        self.viewSize = viewSize
        self.scaleFactor = scaleFactor
    }
}
