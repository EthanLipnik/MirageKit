//
//  AudioPacketHeader.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/12/26.
//

import Foundation

/// Fixed-size audio frame packet header.
package struct AudioPacketHeader {
    /// Magic number for validation ("MIRA").
    package var magic: UInt32 = mirageAudioRegistrationMagic

    /// Protocol version.
    package var version: UInt32 = mirageProtocolVersion

    /// Wire codec.
    package var codec: MirageAudioCodec

    /// Packet flags.
    package var flags: AudioPacketFlags

    /// Reserved for future use.
    package var reserved: UInt8 = 0

    /// Associated stream identifier.
    package var streamID: StreamID

    /// Packet sequence number (per stream).
    package var sequenceNumber: UInt32

    /// Presentation timestamp in nanoseconds.
    package var timestamp: UInt64

    /// Encoded frame number within stream.
    package var frameNumber: UInt32

    /// Fragment index within frame.
    package var fragmentIndex: UInt16

    /// Total fragments for this frame.
    package var fragmentCount: UInt16

    /// Payload length in bytes.
    package var payloadLength: UInt16

    /// Total encoded frame size in bytes.
    package var frameByteCount: UInt32

    /// Output sample rate in Hz.
    package var sampleRate: UInt32

    /// Output channel count.
    package var channelCount: UInt8

    /// Number of PCM samples per channel in this encoded frame.
    package var samplesPerFrame: UInt16

    /// CRC32 checksum for unencrypted payload bytes; encrypted packets set `0` because AEAD provides integrity.
    package var checksum: UInt32

    package init(
        codec: MirageAudioCodec,
        flags: AudioPacketFlags = [],
        streamID: StreamID,
        sequenceNumber: UInt32,
        timestamp: UInt64,
        frameNumber: UInt32,
        fragmentIndex: UInt16,
        fragmentCount: UInt16,
        payloadLength: UInt16,
        frameByteCount: UInt32,
        sampleRate: UInt32,
        channelCount: UInt8,
        samplesPerFrame: UInt16,
        checksum: UInt32
    ) {
        self.codec = codec
        self.flags = flags
        self.streamID = streamID
        self.sequenceNumber = sequenceNumber
        self.timestamp = timestamp
        self.frameNumber = frameNumber
        self.fragmentIndex = fragmentIndex
        self.fragmentCount = fragmentCount
        self.payloadLength = payloadLength
        self.frameByteCount = frameByteCount
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.samplesPerFrame = samplesPerFrame
        self.checksum = checksum
    }

    /// Serializes the audio header to its fixed-width little-endian wire layout.
    package func serialize() -> Data {
        var data = Data(capacity: mirageAudioHeaderSize)
        withUnsafeBytes(of: magic.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: version.littleEndian) { data.append(contentsOf: $0) }
        data.append(codec.rawValue)
        data.append(flags.rawValue)
        data.append(reserved)
        withUnsafeBytes(of: streamID.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: sequenceNumber.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: timestamp.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: frameNumber.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: fragmentIndex.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: fragmentCount.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: payloadLength.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: frameByteCount.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: sampleRate.littleEndian) { data.append(contentsOf: $0) }
        data.append(channelCount)
        withUnsafeBytes(of: samplesPerFrame.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: checksum.littleEndian) { data.append(contentsOf: $0) }
        return data
    }

    /// Deserializes an audio packet header from its fixed-width wire layout.
    package static func deserialize(from data: Data) -> AudioPacketHeader? {
        guard data.count >= mirageAudioHeaderSize else { return nil }

        var offset = 0

        func read<T: FixedWidthInteger>() -> T {
            let value = data.withUnsafeBytes { ptr in
                ptr.loadUnaligned(fromByteOffset: offset, as: T.self)
            }
            offset += MemoryLayout<T>.size
            return T(littleEndian: value)
        }

        func readByte() -> UInt8 {
            let value = data[offset]
            offset += 1
            return value
        }

        let magic: UInt32 = read()
        guard magic == mirageAudioRegistrationMagic else { return nil }

        let version: UInt32 = read()
        guard version == mirageProtocolVersion else { return nil }

        let codecRaw = readByte()
        guard let codec = MirageAudioCodec(rawValue: codecRaw) else { return nil }
        let flags = AudioPacketFlags(rawValue: readByte())
        _ = readByte() // reserved
        let streamID: StreamID = read()
        let sequenceNumber: UInt32 = read()
        let timestamp: UInt64 = read()
        let frameNumber: UInt32 = read()
        let fragmentIndex: UInt16 = read()
        let fragmentCount: UInt16 = read()
        let payloadLength: UInt16 = read()
        let frameByteCount: UInt32 = read()
        let sampleRate: UInt32 = read()
        let channelCount = readByte()
        let samplesPerFrame: UInt16 = read()
        let checksum: UInt32 = read()

        return AudioPacketHeader(
            codec: codec,
            flags: flags,
            streamID: streamID,
            sequenceNumber: sequenceNumber,
            timestamp: timestamp,
            frameNumber: frameNumber,
            fragmentIndex: fragmentIndex,
            fragmentCount: fragmentCount,
            payloadLength: payloadLength,
            frameByteCount: frameByteCount,
            sampleRate: sampleRate,
            channelCount: channelCount,
            samplesPerFrame: samplesPerFrame,
            checksum: checksum
        )
    }
}

package struct AudioPacketFlags: OptionSet {
    package let rawValue: UInt8

    package init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    /// Stream discontinuity (decoder should reset buffer state).
    package static let discontinuity = AudioPacketFlags(rawValue: 1 << 0)
    /// Payload is encrypted with session media key.
    package static let encryptedPayload = AudioPacketFlags(rawValue: 1 << 1)
}
