//
//  AudioPacketizer.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/6/26.
//
//  Audio packet fragmentation for UDP transport.
//

import Foundation
import MirageKit

#if os(macOS)

actor AudioPacketizer {
    private let maxPayloadSize: Int
    private let mediaSecurityKey: MirageMediaPacketKey?
    private var frameNumber: UInt32 = 0
    private var sequenceNumber: UInt32 = 0

    init(
        maxPayloadSize: Int,
        mediaSecurityContext: MirageMediaSecurityContext? = nil
    ) {
        self.maxPayloadSize = max(1, maxPayloadSize)
        mediaSecurityKey = mediaSecurityContext.map { MirageMediaSecurity.makePacketKey(context: $0) }
    }

    func resetCounters() {
        frameNumber = 0
        sequenceNumber = 0
    }

    func packetize(
        frame: EncodedAudioFrame,
        streamID: StreamID,
        discontinuity: Bool = false
    ) -> [Data] {
        guard !frame.data.isEmpty else { return [] }
        let fragmentCount = max(1, (frame.data.count + maxPayloadSize - 1) / maxPayloadSize)
        let totalFragments = min(fragmentCount, Int(UInt16.max))
        let currentFrameNumber = frameNumber
        frameNumber &+= 1

        var packets: [Data] = []
        packets.reserveCapacity(totalFragments)

        frame.data.withUnsafeBytes { frameBytes in
            for fragmentIndex in 0 ..< totalFragments {
                let start = fragmentIndex * maxPayloadSize
                let end = min(frame.data.count, start + maxPayloadSize)
                let payloadCount = max(0, end - start)
                guard payloadCount > 0 else { continue }
                let payloadBytes = UnsafeRawBufferPointer(rebasing: frameBytes[start ..< end])
                let checksum: UInt32 = if mediaSecurityKey == nil {
                    CRC32.calculate(payloadBytes)
                } else {
                    0
                }
                var flags: AudioPacketFlags = []
                if discontinuity, fragmentIndex == 0 { flags.insert(.discontinuity) }
                if mediaSecurityKey != nil { flags.insert(.encryptedPayload) }

                let header = AudioPacketHeader(
                    codec: frame.codec,
                    flags: flags,
                    streamID: streamID,
                    sequenceNumber: sequenceNumber,
                    timestamp: frame.timestampNs,
                    frameNumber: currentFrameNumber,
                    fragmentIndex: UInt16(fragmentIndex),
                    fragmentCount: UInt16(totalFragments),
                    payloadLength: UInt16(payloadCount),
                    frameByteCount: UInt32(frame.data.count),
                    sampleRate: UInt32(frame.sampleRate),
                    channelCount: UInt8(frame.channelCount),
                    samplesPerFrame: UInt16(clamping: frame.samplesPerFrame),
                    checksum: checksum
                )
                sequenceNumber &+= 1

                if let mediaSecurityKey {
                    do {
                        let wirePayload = try MirageMediaSecurity.encryptAudioPayload(
                            payloadBytes,
                            header: header,
                            key: mediaSecurityKey,
                            direction: .hostToClient
                        )
                        var packet = header.serialize()
                        packet.reserveCapacity(mirageAudioHeaderSize + wirePayload.count)
                        packet.append(wirePayload)
                        packets.append(packet)
                    } catch {
                        MirageLogger.error(
                            .host,
                            "Failed to encrypt audio packet stream \(streamID) frame \(currentFrameNumber) seq \(header.sequenceNumber): \(error)"
                        )
                    }
                } else {
                    guard let payloadBase = payloadBytes.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                        continue
                    }
                    var packet = header.serialize()
                    packet.reserveCapacity(mirageAudioHeaderSize + payloadCount)
                    packet.append(payloadBase, count: payloadCount)
                    packets.append(packet)
                }
            }
        }

        return packets
    }
}

#endif
