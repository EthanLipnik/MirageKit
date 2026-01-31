//
//  AudioPacketSender.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/30/26.
//
//  Audio packetization for UDP transport.
//

import Foundation

#if os(macOS)
struct AudioEncodedFrame: Sendable {
    let data: Data
    let timestamp: UInt64
    let flags: AudioFlags
    let config: MirageAudioConfiguration
}

final class AudioPacketSender {
    private let maxPacketSize: Int
    private var sequenceNumber: UInt32 = 0
    private var epoch: UInt16 = 0

    init(maxPacketSize: Int) {
        self.maxPacketSize = maxPacketSize
    }

    func resetEpoch() {
        epoch &+= 1
        sequenceNumber = 0
    }

    func packets(for frame: AudioEncodedFrame) -> [Data] {
        let maxPayload = max(0, maxPacketSize - MirageAudioHeaderSize)
        guard maxPayload > 0 else { return [] }

        let bytesPerFrame = frame.config.codec == .pcmFloat32 ? max(1, frame.config.channelCount) * 4 : 1
        let alignedPayload = maxPayload - (maxPayload % bytesPerFrame)
        let payloadSize = max(1, alignedPayload)

        if frame.config.codec == .aacLc, frame.data.count > payloadSize {
            MirageLogger.error(.host, "AAC packet exceeds max UDP payload (\(frame.data.count) > \(payloadSize)); dropping audio packet")
            return []
        }

        let data = frame.data
        let totalFragments = max(1, Int(ceil(Double(data.count) / Double(payloadSize))))

        var packets: [Data] = []
        packets.reserveCapacity(totalFragments)

        let codecByte = audioCodecByte(frame.config.codec)
        let layoutByte = audioLayoutByte(frame.config.channelLayout)
        let channelCount = UInt8(max(0, frame.config.channelCount))
        let sampleRate = UInt32(max(0, frame.config.sampleRate))

        var fragmentTimestamp = frame.timestamp

        for fragmentIndex in 0..<totalFragments {
            let start = fragmentIndex * payloadSize
            let end = min(start + payloadSize, data.count)
            let fragment = data.subdata(in: start..<end)

            let fragmentFlags: AudioFlags = fragmentIndex == 0 ? frame.flags : []

            let header = AudioPacketHeader(
                flags: fragmentFlags,
                sequenceNumber: sequenceNumber,
                timestamp: fragmentTimestamp,
                payloadLength: UInt32(fragment.count),
                epoch: epoch,
                codec: codecByte,
                channelCount: channelCount,
                sampleRate: sampleRate,
                channelLayout: layoutByte
            )

            sequenceNumber &+= 1

            if frame.config.codec == .pcmFloat32, frame.config.sampleRate > 0 {
                let framesInFragment = fragment.count / bytesPerFrame
                let durationSeconds = Double(framesInFragment) / Double(frame.config.sampleRate)
                let durationNanos = UInt64(durationSeconds * 1_000_000_000)
                fragmentTimestamp &+= durationNanos
            }

            var packet = Data(capacity: MirageAudioHeaderSize + fragment.count)
            packet.append(header.serialize())
            packet.append(fragment)
            packets.append(packet)
        }

        return packets
    }

    private func audioCodecByte(_ codec: MirageAudioCodec) -> UInt8 {
        switch codec {
        case .aacLc: return 1
        case .pcmFloat32: return 2
        }
    }

    private func audioLayoutByte(_ layout: MirageAudioChannelLayout) -> UInt8 {
        switch layout {
        case .mono: return 1
        case .stereo: return 2
        case .surround5_1: return 6
        case .source: return 0
        }
    }
}
#endif
