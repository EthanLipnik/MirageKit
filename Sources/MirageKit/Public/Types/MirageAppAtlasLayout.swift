//
//  MirageAppAtlasLayout.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/1/26.
//

import CoreGraphics

/// Describes the region of a logical app window inside a physical app-atlas media stream.
public struct MirageAppAtlasRegion: Codable, Sendable, Equatable {
    /// Logical host window identity represented by this atlas region.
    public let windowID: WindowID
    /// Region origin in the physical media stream's pixel coordinate space.
    public let x: Int
    /// Region origin in the physical media stream's pixel coordinate space.
    public let y: Int
    /// Region width in physical media-stream pixels.
    public let width: Int
    /// Region height in physical media-stream pixels.
    public let height: Int
    /// Front-to-back ordering within the atlas when regions overlap.
    public let zIndex: Int
    /// Whether this region is the host-focused logical app window.
    public let isFocused: Bool
    /// Whether this region should be rendered by clients.
    public let isVisible: Bool

    /// Creates a logical app-window region inside an app-atlas media stream.
    public init(
        windowID: WindowID,
        x: Int,
        y: Int,
        width: Int,
        height: Int,
        zIndex: Int = 0,
        isFocused: Bool = false,
        isVisible: Bool = true
    ) {
        self.windowID = windowID
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.zIndex = zIndex
        self.isFocused = isFocused
        self.isVisible = isVisible
    }

    /// Region rectangle in physical media-stream pixel coordinates.
    public var pixelRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }

    /// Region rectangle normalized to the atlas canvas.
    public func normalizedRect(in layout: MirageAppAtlasLayout) -> CGRect {
        guard layout.width > 0, layout.height > 0 else { return .zero }
        return CGRect(
            x: CGFloat(x) / CGFloat(layout.width),
            y: CGFloat(y) / CGFloat(layout.height),
            width: CGFloat(width) / CGFloat(layout.width),
            height: CGFloat(height) / CGFloat(layout.height)
        )
    }
}

/// Describes a physical app-atlas media stream and the logical window regions packed into it.
public struct MirageAppAtlasLayout: Codable, Sendable, Equatable {
    /// Physical media stream carrying the atlas.
    public let mediaStreamID: StreamID
    /// Monotonic layout generation for this media stream.
    public let layoutEpoch: UInt64
    /// Atlas width in encoded media-stream pixels.
    public let width: Int
    /// Atlas height in encoded media-stream pixels.
    public let height: Int
    /// Logical app-window regions inside this physical media stream.
    public let regions: [MirageAppAtlasRegion]

    /// Creates an app-atlas layout for one physical media stream.
    public init(
        mediaStreamID: StreamID,
        layoutEpoch: UInt64 = 0,
        width: Int,
        height: Int,
        regions: [MirageAppAtlasRegion]
    ) {
        self.mediaStreamID = mediaStreamID
        self.layoutEpoch = layoutEpoch
        self.width = width
        self.height = height
        self.regions = regions
    }

    /// Atlas canvas size in physical media-stream pixels.
    public var canvasSize: CGSize {
        CGSize(width: width, height: height)
    }

    /// Whether the atlas currently has no logical window regions.
    public var isEmpty: Bool {
        regions.isEmpty
    }

    /// Returns the atlas region for a logical host window, if present.
    public func region(for windowID: WindowID) -> MirageAppAtlasRegion? {
        regions.first { $0.windowID == windowID }
    }
}
