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
    package let pixelFormat: MiragePixelFormat?
    package let colorSpace: MirageColorSpace?
    package let bitrate: Int?
    package let streamScale: CGFloat?

    package init(
        streamID: StreamID,
        pixelFormat: MiragePixelFormat? = nil,
        colorSpace: MirageColorSpace? = nil,
        bitrate: Int? = nil,
        streamScale: CGFloat? = nil
    ) {
        self.streamID = streamID
        self.pixelFormat = pixelFormat
        self.colorSpace = colorSpace
        self.bitrate = bitrate
        self.streamScale = streamScale
    }
}
