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
    package let bitDepth: MirageVideoBitDepth?
    package let bitrate: Int?
    package let streamScale: CGFloat?

    package init(
        streamID: StreamID,
        bitDepth: MirageVideoBitDepth? = nil,
        bitrate: Int? = nil,
        streamScale: CGFloat? = nil
    ) {
        self.streamID = streamID
        self.bitDepth = bitDepth
        self.bitrate = bitrate
        self.streamScale = streamScale
    }
}
