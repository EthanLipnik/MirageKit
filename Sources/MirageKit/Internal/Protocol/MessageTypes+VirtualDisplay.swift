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

/// Requests a host-side capture or virtual-display resize for an active stream.
///
/// Clients send this when their render target changes size, scale, or encoder
/// pixel budget.
package struct DisplayResolutionChangeMessage: Codable {
    /// The stream to update.
    package let streamID: StreamID
    /// New logical display width in points.
    package let displayWidth: Int
    /// New logical display height in points.
    package let displayHeight: Int
    /// Desktop-only transition identifier for stale resize suppression.
    package var transitionID: UUID?
    /// Desktop-only requested backing scale factor for logical -> pixel mapping.
    package var requestedDisplayScaleFactor: CGFloat?
    /// Desktop-only requested stream scale before host-side capping.
    package var requestedStreamScale: CGFloat?
    /// Desktop-only maximum encoded width in pixels for host-side geometry resolution.
    package var encoderMaxWidth: Int?
    /// Desktop-only maximum encoded height in pixels for host-side geometry resolution.
    package var encoderMaxHeight: Int?
    /// Desktop-only geometry contract identity for stale resize suppression.
    package var desktopGeometryContractID: UUID?
    /// Desktop-only diagnostic scene identity for the drawable that produced this resize geometry.
    package var desktopGeometrySceneIdentity: String?
    /// Desktop-only refresh target associated with this resize geometry.
    package var desktopGeometryRefreshTargetHz: Int?

    package init(
        streamID: StreamID,
        displayWidth: Int,
        displayHeight: Int,
        transitionID: UUID? = nil,
        requestedDisplayScaleFactor: CGFloat? = nil,
        requestedStreamScale: CGFloat? = nil,
        encoderMaxWidth: Int? = nil,
        encoderMaxHeight: Int? = nil,
        desktopGeometryContractID: UUID? = nil,
        desktopGeometrySceneIdentity: String? = nil,
        desktopGeometryRefreshTargetHz: Int? = nil
    ) {
        self.streamID = streamID
        self.displayWidth = displayWidth
        self.displayHeight = displayHeight
        self.transitionID = transitionID
        self.requestedDisplayScaleFactor = requestedDisplayScaleFactor
        self.requestedStreamScale = requestedStreamScale
        self.encoderMaxWidth = encoderMaxWidth
        self.encoderMaxHeight = encoderMaxHeight
        self.desktopGeometryContractID = desktopGeometryContractID
        self.desktopGeometrySceneIdentity = desktopGeometrySceneIdentity
        self.desktopGeometryRefreshTargetHz = desktopGeometryRefreshTargetHz
    }
}

/// Requests post-capture stream scaling without resizing the host display or window.
package struct StreamScaleChangeMessage: Codable {
    /// The stream to update.
    package let streamID: StreamID
    /// Stream scale factor in the supported runtime range.
    package let streamScale: CGFloat

    package init(streamID: StreamID, streamScale: CGFloat) {
        self.streamID = streamID
        self.streamScale = streamScale
    }
}

/// Requests a new maximum capture cadence for an active stream.
package struct StreamRefreshRateChangeMessage: Codable {
    /// The stream to update.
    package let streamID: StreamID
    /// Maximum refresh rate in Hz requested by the client.
    package let maxRefreshRate: Int
    /// Force a display refresh reconfiguration on the host.
    package var forceDisplayRefresh: Bool

    package init(streamID: StreamID, maxRefreshRate: Int, forceDisplayRefresh: Bool = false) {
        self.streamID = streamID
        self.maxRefreshRate = maxRefreshRate
        self.forceDisplayRefresh = forceDisplayRefresh
    }
}
