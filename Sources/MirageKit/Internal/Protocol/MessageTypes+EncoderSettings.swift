//
//  MessageTypes+EncoderSettings.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/5/26.
//
//  Runtime encoder setting update messages.
//

import CoreGraphics
import Foundation

package struct StreamEncoderSettingsChangeMessage: Codable {
    package let requestID: UUID
    package let streamID: StreamID
    package let colorDepth: MirageStreamColorDepth?
    package let bitrate: Int?
    package let streamScale: CGFloat?
    package let targetFrameRate: Int?

    package init(
        requestID: UUID,
        streamID: StreamID,
        colorDepth: MirageStreamColorDepth? = nil,
        bitrate: Int? = nil,
        streamScale: CGFloat? = nil,
        targetFrameRate: Int? = nil
    ) {
        self.requestID = requestID
        self.streamID = streamID
        self.colorDepth = colorDepth
        self.bitrate = bitrate
        self.streamScale = streamScale
        self.targetFrameRate = targetFrameRate
    }
}

package struct StreamEncoderSettingsChangeAckMessage: Codable, Sendable, Equatable {
    package let requestID: UUID
    package let streamID: StreamID
    package let encodedWidth: Int
    package let encodedHeight: Int
    package let frameRate: Int
    package let colorDepth: MirageStreamColorDepth
    package let dimensionToken: UInt16
    package let requiresReset: Bool

    package init(
        requestID: UUID,
        streamID: StreamID,
        encodedWidth: Int,
        encodedHeight: Int,
        frameRate: Int,
        colorDepth: MirageStreamColorDepth,
        dimensionToken: UInt16,
        requiresReset: Bool
    ) {
        self.requestID = requestID
        self.streamID = streamID
        self.encodedWidth = encodedWidth
        self.encodedHeight = encodedHeight
        self.frameRate = frameRate
        self.colorDepth = colorDepth
        self.dimensionToken = dimensionToken
        self.requiresReset = requiresReset
    }
}
