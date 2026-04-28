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
    package let streamID: StreamID
    package let colorDepth: MirageStreamColorDepth?
    package let bitrate: Int?
    package let streamScale: CGFloat?
    package let targetFrameRate: Int?

    package init(
        streamID: StreamID,
        colorDepth: MirageStreamColorDepth? = nil,
        bitrate: Int? = nil,
        streamScale: CGFloat? = nil,
        targetFrameRate: Int? = nil
    ) {
        self.streamID = streamID
        self.colorDepth = colorDepth
        self.bitrate = bitrate
        self.streamScale = streamScale
        self.targetFrameRate = targetFrameRate
    }
}
