//
//  MessageTypes+Audio.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/30/26.
//
//  Message type definitions.
//

import Foundation

// MARK: - Audio Messages

struct AudioConfigMessage: Codable {
    let mode: MirageAudioMode
    let quality: MirageAudioQuality
    let matchVideoQuality: Bool
    let codec: MirageAudioCodec
    let sampleRate: Int
    let channelCount: Int
    let channelLayout: MirageAudioChannelLayout
    let bitrate: Int?
}

struct AudioStreamStartedMessage: Codable {
    let audioPort: UInt16
    let config: AudioConfigMessage
}

struct AudioStreamStoppedMessage: Codable {
    let reason: String
}
