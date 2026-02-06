//
//  MessageTypes+VirtualDisplay.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Message type definitions.
//

import CoreGraphics
import Foundation

// MARK: - Virtual Display Messages

/// Content bounds update sent from host to client when content area changes
/// This happens when menus, sheets, or panels appear on the virtual display
package struct ContentBoundsUpdateMessage: Codable {
    /// The stream this update applies to
    package let streamID: StreamID
    /// New content bounds in pixels (origin + size)
    package let boundsX: CGFloat
    package let boundsY: CGFloat
    package let boundsWidth: CGFloat
    package let boundsHeight: CGFloat

    package init(streamID: StreamID, bounds: CGRect) {
        self.streamID = streamID
        boundsX = bounds.origin.x
        boundsY = bounds.origin.y
        boundsWidth = bounds.width
        boundsHeight = bounds.height
    }

    package var bounds: CGRect { CGRect(x: boundsX, y: boundsY, width: boundsWidth, height: boundsHeight) }
}

/// Display resolution change request sent from client to host
/// Used when client window moves to a different physical display
package struct DisplayResolutionChangeMessage: Codable {
    /// The stream to update
    package let streamID: StreamID
    /// New display size in points (logical view bounds)
    package let displayWidth: Int
    package let displayHeight: Int

    package init(streamID: StreamID, displayWidth: Int, displayHeight: Int) {
        self.streamID = streamID
        self.displayWidth = displayWidth
        self.displayHeight = displayHeight
    }
}

/// Stream scale change request sent from client to host
/// Applies post-capture downscaling without resizing host windows
package struct StreamScaleChangeMessage: Codable {
    /// The stream to update
    package let streamID: StreamID
    /// Stream scale factor (0.1-1.0)
    package let streamScale: CGFloat

    package init(streamID: StreamID, streamScale: CGFloat) {
        self.streamID = streamID
        self.streamScale = streamScale
    }
}

/// Stream refresh rate override sent from client to host
/// Controls whether the host targets 60 Hz or 120 Hz for this stream
package struct StreamRefreshRateChangeMessage: Codable {
    /// The stream to update
    package let streamID: StreamID
    /// Maximum refresh rate in Hz (60/120 based on client capability)
    package let maxRefreshRate: Int
    /// Force a display refresh reconfiguration on the host (fallback path)
    package var forceDisplayRefresh: Bool?

    package init(streamID: StreamID, maxRefreshRate: Int, forceDisplayRefresh: Bool? = nil) {
        self.streamID = streamID
        self.maxRefreshRate = maxRefreshRate
        self.forceDisplayRefresh = forceDisplayRefresh
    }
}
