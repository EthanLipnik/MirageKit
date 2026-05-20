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

/// Requests runtime encoder setting changes for an active stream.
///
/// `nil` fields leave the existing stream setting unchanged.
package struct StreamEncoderSettingsChangeMessage: Codable {
    /// The stream whose encoder settings should be updated.
    package let streamID: StreamID
    /// Optional color-depth override.
    package let colorDepth: MirageStreamColorDepth?
    /// Optional bitrate override in bits per second.
    package let bitrate: Int?
    /// Optional bitrate adaptation ceiling override in bits per second.
    package let bitrateAdaptationCeiling: Int?
    /// Optional stream scale override applied after capture.
    package let streamScale: CGFloat?
    /// Optional target frame rate override in frames per second.
    package let targetFrameRate: Int?

    package init(
        streamID: StreamID,
        colorDepth: MirageStreamColorDepth? = nil,
        bitrate: Int? = nil,
        bitrateAdaptationCeiling: Int? = nil,
        streamScale: CGFloat? = nil,
        targetFrameRate: Int? = nil
    ) {
        self.streamID = streamID
        self.colorDepth = colorDepth
        self.bitrate = bitrate
        self.bitrateAdaptationCeiling = bitrateAdaptationCeiling
        self.streamScale = streamScale
        self.targetFrameRate = targetFrameRate
    }
}
