//
//  MirageAudioMessages.swift
//  MirageWire
//
//  Created by Ethan Lipnik on 6/5/26.
//

import Foundation
import MirageCore
import MirageMedia

// MARK: - Audio Streaming Messages

package struct AudioStreamStartedMessage: Codable, Equatable, Sendable {
    package let streamID: StreamID
    package let codec: MirageMedia.MirageAudioCodec
    package let sampleRate: Int
    package let channelCount: Int

    package init(
        streamID: StreamID,
        codec: MirageMedia.MirageAudioCodec,
        sampleRate: Int,
        channelCount: Int
    ) {
        self.streamID = streamID
        self.codec = codec
        self.sampleRate = sampleRate
        self.channelCount = channelCount
    }
}

package struct AudioStreamStoppedMessage: Codable, Equatable, Sendable {
    package let streamID: StreamID
    package let reason: AudioStreamStopReason

    package init(streamID: StreamID, reason: AudioStreamStopReason) {
        self.streamID = streamID
        self.reason = reason
    }
}

package enum AudioStreamStopReason: String, Codable, Sendable {
    case clientRequested
    case sourceStopped
    case disabled
    case error
}
