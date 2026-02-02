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
struct ContentBoundsUpdateMessage: Codable {
    /// The stream this update applies to
    let streamID: StreamID
    /// New content bounds in pixels (origin + size)
    let boundsX: CGFloat
    let boundsY: CGFloat
    let boundsWidth: CGFloat
    let boundsHeight: CGFloat

    init(streamID: StreamID, bounds: CGRect) {
        self.streamID = streamID
        boundsX = bounds.origin.x
        boundsY = bounds.origin.y
        boundsWidth = bounds.width
        boundsHeight = bounds.height
    }

    var bounds: CGRect { CGRect(x: boundsX, y: boundsY, width: boundsWidth, height: boundsHeight) }
}

/// Display resolution change request sent from client to host
/// Used when client window moves to a different physical display
struct DisplayResolutionChangeMessage: Codable {
    /// The stream to update
    let streamID: StreamID
    /// New display resolution in pixels
    let displayWidth: Int
    let displayHeight: Int
}

/// Stream scale change request sent from client to host
/// Applies post-capture downscaling without resizing host windows
struct StreamScaleChangeMessage: Codable {
    /// The stream to update
    let streamID: StreamID
    /// Stream scale factor (0.1-1.0)
    let streamScale: CGFloat
}

/// Stream refresh rate override sent from client to host
/// Controls whether the host targets 60 Hz or 120 Hz for this stream
struct StreamRefreshRateChangeMessage: Codable {
    /// The stream to update
    let streamID: StreamID
    /// Maximum refresh rate in Hz (60/120 based on client capability)
    let maxRefreshRate: Int
    /// Force a display refresh reconfiguration on the host (fallback path)
    var forceDisplayRefresh: Bool?
}
