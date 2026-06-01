//
//  MirageProtocol.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/2/26.
//

import CoreGraphics
import Foundation

/// Magic number for packet validation
package let mirageProtocolMagic: UInt32 = 0x4D49_5247 // "MIRG"

/// Mirage wire-contract version for session bootstrap and media packets, encoded as YYMMDD.
package let mirageProtocolVersion: UInt32 = 260531

/// Registration packet magic values.
package let mirageAudioRegistrationMagic: UInt32 = 0x4D49_5241 // "MIRA"

/// Default maximum UDP packet size (header + payload) to avoid IPv6 fragmentation.
/// 1200 bytes keeps packets under the IPv6 minimum MTU (1280) once IP/UDP headers are added.
public let mirageDefaultMaxPacketSize: Int = 1200

private enum MiragePacketHeaderFieldSize {
    static let uint8 = MemoryLayout<UInt8>.size
    static let uint16 = MemoryLayout<UInt16>.size
    static let uint32 = MemoryLayout<UInt32>.size
    static let uint64 = MemoryLayout<UInt64>.size
    static let float32 = MemoryLayout<Float32>.size
}

/// Video packet header size in bytes.
package let mirageHeaderSize: Int =
    MiragePacketHeaderFieldSize.uint32 + // magic
    MiragePacketHeaderFieldSize.uint32 + // version
    MiragePacketHeaderFieldSize.uint16 + // flags
    MiragePacketHeaderFieldSize.uint16 + // streamID
    MiragePacketHeaderFieldSize.uint32 + // sequenceNumber
    MiragePacketHeaderFieldSize.uint64 + // timestamp
    MiragePacketHeaderFieldSize.uint32 + // frameNumber
    MiragePacketHeaderFieldSize.uint16 + // fragmentIndex
    MiragePacketHeaderFieldSize.uint16 + // fragmentCount
    MiragePacketHeaderFieldSize.uint8 + // fecBlockSize
    MiragePacketHeaderFieldSize.uint32 + // payloadLength
    MiragePacketHeaderFieldSize.uint32 + // frameByteCount
    MiragePacketHeaderFieldSize.uint32 + // checksum
    (4 * MiragePacketHeaderFieldSize.float32) + // contentRect
    MiragePacketHeaderFieldSize.uint16 + // dimensionToken
    MiragePacketHeaderFieldSize.uint16 // epoch

/// Audio packet header size in bytes.
package let mirageAudioHeaderSize: Int =
    MiragePacketHeaderFieldSize.uint32 + // magic
    MiragePacketHeaderFieldSize.uint32 + // version
    MiragePacketHeaderFieldSize.uint8 + // codec
    MiragePacketHeaderFieldSize.uint8 + // flags
    MiragePacketHeaderFieldSize.uint8 + // reserved
    MiragePacketHeaderFieldSize.uint16 + // streamID
    MiragePacketHeaderFieldSize.uint32 + // sequenceNumber
    MiragePacketHeaderFieldSize.uint64 + // timestamp
    MiragePacketHeaderFieldSize.uint32 + // frameNumber
    MiragePacketHeaderFieldSize.uint16 + // fragmentIndex
    MiragePacketHeaderFieldSize.uint16 + // fragmentCount
    MiragePacketHeaderFieldSize.uint16 + // payloadLength
    MiragePacketHeaderFieldSize.uint32 + // frameByteCount
    MiragePacketHeaderFieldSize.uint32 + // sampleRate
    MiragePacketHeaderFieldSize.uint8 + // channelCount
    MiragePacketHeaderFieldSize.uint16 + // samplesPerFrame
    MiragePacketHeaderFieldSize.uint32 // checksum

/// AEAD authentication tag size (AES-256-GCM).
package let mirageMediaAuthTagSize: Int = 16

/// Compute payload size from the configured maximum packet size.
/// `maxPacketSize` includes the Mirage header; this returns the payload size only.
package func miragePayloadSize(maxPacketSize: Int) -> Int {
    // Reserve room for AEAD tag so encrypted payloads stay within max packet size.
    let payload = maxPacketSize - mirageHeaderSize - mirageMediaAuthTagSize
    if payload > 0 { return payload }
    return mirageDefaultMaxPacketSize - mirageHeaderSize - mirageMediaAuthTagSize
}

/// Fixed-size video frame packet header.
package struct FrameHeader {
    /// Magic number for validation (0x4D495247 = "MIRG")
    package var magic: UInt32 = mirageProtocolMagic

    /// Protocol version.
    package var version: UInt32 = mirageProtocolVersion

    /// Packet flags
    package var flags: FrameFlags

    /// Stream identifier (for multiplexing)
    package var streamID: StreamID

    /// Packet sequence number (per-stream)
    package var sequenceNumber: UInt32

    /// Presentation timestamp in nanoseconds
    package var timestamp: UInt64

    /// Frame number within stream
    package var frameNumber: UInt32

    /// Fragment index within frame
    package var fragmentIndex: UInt16

    /// Total fragments for this frame
    package var fragmentCount: UInt16

    /// Effective FEC block size used by the sender for this frame.
    /// `0` means no parity fragments are present.
    package var fecBlockSize: UInt8

    /// Payload length in bytes
    package var payloadLength: UInt32

    /// Total encoded frame length in bytes (data only, excludes parity)
    package var frameByteCount: UInt32

    /// CRC32 checksum of unencrypted payload bytes; encrypted packets set `0` because AEAD provides integrity.
    package var checksum: UInt32

    /// Content rectangle within the frame buffer (x, y, width, height in pixels)
    /// When ScreenCaptureKit can't fill the buffer, content is at top-left with black padding.
    /// This tells the renderer where the actual content is.
    package var contentRectX: Float32 = 0
    package var contentRectY: Float32 = 0
    package var contentRectWidth: Float32 = 0
    package var contentRectHeight: Float32 = 0

    /// Dimension token for rejecting old-dimension P-frames after resize.
    /// Incremented each time encoder dimensions change. Client compares this
    /// to expected token and silently discards frames with mismatched tokens.
    package var dimensionToken: UInt16 = 0

    /// Stream epoch for discontinuity boundaries.
    /// Incremented when the host resets send state or restarts capture.
    package var epoch: UInt16 = 0

    package init(
        flags: FrameFlags = [],
        streamID: StreamID,
        sequenceNumber: UInt32,
        timestamp: UInt64,
        frameNumber: UInt32,
        fragmentIndex: UInt16,
        fragmentCount: UInt16,
        fecBlockSize: UInt8 = 0,
        payloadLength: UInt32,
        frameByteCount: UInt32,
        checksum: UInt32,
        contentRect: CGRect = .zero,
        dimensionToken: UInt16 = 0,
        epoch: UInt16 = 0
    ) {
        self.flags = flags
        self.streamID = streamID
        self.sequenceNumber = sequenceNumber
        self.timestamp = timestamp
        self.frameNumber = frameNumber
        self.fragmentIndex = fragmentIndex
        self.fragmentCount = fragmentCount
        self.fecBlockSize = fecBlockSize
        self.payloadLength = payloadLength
        self.frameByteCount = frameByteCount
        self.checksum = checksum
        contentRectX = Float32(contentRect.origin.x)
        contentRectY = Float32(contentRect.origin.y)
        contentRectWidth = Float32(contentRect.size.width)
        contentRectHeight = Float32(contentRect.size.height)
        self.dimensionToken = dimensionToken
        self.epoch = epoch
    }

    /// Content rectangle represented as a Core Graphics rectangle.
    package var contentRect: CGRect {
        CGRect(
            x: CGFloat(contentRectX),
            y: CGFloat(contentRectY),
            width: CGFloat(contentRectWidth),
            height: CGFloat(contentRectHeight)
        )
    }

    /// Serializes the header to its fixed-width little-endian wire layout.
    package func serialize() -> Data {
        var data = Data(capacity: mirageHeaderSize)

        withUnsafeBytes(of: magic.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: version.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: flags.rawValue.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: streamID.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: sequenceNumber.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: timestamp.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: frameNumber.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: fragmentIndex.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: fragmentCount.littleEndian) { data.append(contentsOf: $0) }
        data.append(fecBlockSize)
        withUnsafeBytes(of: payloadLength.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: frameByteCount.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: checksum.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: contentRectX.bitPattern.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: contentRectY.bitPattern.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: contentRectWidth.bitPattern.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: contentRectHeight.bitPattern.littleEndian) { data.append(contentsOf: $0) }

        // Dimension token (2 bytes)
        withUnsafeBytes(of: dimensionToken.littleEndian) { data.append(contentsOf: $0) }

        // Epoch (2 bytes)
        withUnsafeBytes(of: epoch.littleEndian) { data.append(contentsOf: $0) }

        return data
    }

    /// Serialize header into a preallocated buffer.
    package func serialize(into buffer: UnsafeMutableRawBufferPointer) {
        guard buffer.count >= mirageHeaderSize, buffer.baseAddress != nil else { return }
        var offset = 0

        func write(_ value: some FixedWidthInteger) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { bytes in
                let end = offset + bytes.count
                guard end <= buffer.count else { return }
                buffer[offset ..< end].copyBytes(from: bytes)
                offset = end
            }
        }

        func writeFloat32(_ value: Float32) {
            write(value.bitPattern)
        }

        write(magic)
        write(version)
        write(flags.rawValue)
        write(streamID)
        write(sequenceNumber)
        write(timestamp)
        write(frameNumber)
        write(fragmentIndex)
        write(fragmentCount)
        write(fecBlockSize)
        write(payloadLength)
        write(frameByteCount)
        write(checksum)
        writeFloat32(contentRectX)
        writeFloat32(contentRectY)
        writeFloat32(contentRectWidth)
        writeFloat32(contentRectHeight)
        write(dimensionToken)
        write(epoch)
    }

    /// Deserializes a fixed-width little-endian header from packet bytes.
    package static func deserialize(from data: Data) -> FrameHeader? {
        guard data.count >= mirageHeaderSize else { return nil }

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

        func readFloat32() -> Float32 {
            let bits: UInt32 = read()
            return Float32(bitPattern: bits)
        }

        let magic: UInt32 = read()
        guard magic == mirageProtocolMagic else { return nil }

        let version: UInt32 = read()
        guard version == mirageProtocolVersion else { return nil }

        let flagsRaw: UInt16 = read()
        let flags = FrameFlags(rawValue: flagsRaw)
        let streamID: UInt16 = read()
        let sequenceNumber: UInt32 = read()
        let timestamp: UInt64 = read()
        let frameNumber: UInt32 = read()
        let fragmentIndex: UInt16 = read()
        let fragmentCount: UInt16 = read()
        let fecBlockSize = readByte()
        let payloadLength: UInt32 = read()
        let frameByteCount: UInt32 = read()
        let checksum: UInt32 = read()
        let contentRectX = readFloat32()
        let contentRectY = readFloat32()
        let contentRectWidth = readFloat32()
        let contentRectHeight = readFloat32()

        // Dimension token
        let dimensionToken: UInt16 = read()

        // Epoch
        let epoch: UInt16 = read()

        return FrameHeader(
            flags: flags,
            streamID: streamID,
            sequenceNumber: sequenceNumber,
            timestamp: timestamp,
            frameNumber: frameNumber,
            fragmentIndex: fragmentIndex,
            fragmentCount: fragmentCount,
            fecBlockSize: fecBlockSize,
            payloadLength: payloadLength,
            frameByteCount: frameByteCount,
            checksum: checksum,
            contentRect: CGRect(
                x: CGFloat(contentRectX),
                y: CGFloat(contentRectY),
                width: CGFloat(contentRectWidth),
                height: CGFloat(contentRectHeight)
            ),
            dimensionToken: dimensionToken,
            epoch: epoch
        )
    }
}

/// Frame flags
package struct FrameFlags: OptionSet, Sendable {
    package let rawValue: UInt16

    package init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    /// This is a keyframe (IDR frame)
    package static let keyframe = FrameFlags(rawValue: 1 << 0)

    /// This is the last fragment of the frame
    package static let endOfFrame = FrameFlags(rawValue: 1 << 1)

    /// Contains parameter sets (SPS/PPS/VPS)
    package static let parameterSet = FrameFlags(rawValue: 1 << 2)

    /// Stream discontinuity (decoder should reset)
    package static let discontinuity = FrameFlags(rawValue: 1 << 3)

    /// High-priority packet for QoS and ingress recovery.
    package static let priority = FrameFlags(rawValue: 1 << 4)

    /// This is a full desktop stream (virtual display mirroring mode)
    /// Used when client requests streaming of the entire desktop
    package static let desktopStream = FrameFlags(rawValue: 1 << 8)

    /// FEC parity fragment (not part of the encoded frame payload)
    package static let fecParity = FrameFlags(rawValue: 1 << 10)
    /// Payload is encrypted with session media key.
    package static let encryptedPayload = FrameFlags(rawValue: 1 << 11)
    /// Payload is ProRes codec (not HEVC NAL-based)
    package static let proResCodec = FrameFlags(rawValue: 1 << 12)
}

/// CRC32 calculation for packet validation
package enum CRC32 {
    private static let table: [UInt32] = (0 ..< 256).map { i -> UInt32 in
        var crc = UInt32(i)
        for _ in 0 ..< 8 {
            crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1
        }
        return crc
    }

    package static func calculate(_ data: Data) -> UInt32 {
        data.withUnsafeBytes { buffer in
            calculate(buffer)
        }
    }

    package static func calculate(_ buffer: UnsafeRawBufferPointer) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        let bytes = buffer.bindMemory(to: UInt8.self)
        for byte in bytes {
            let index = Int((crc ^ UInt32(byte)) & 0xFF)
            crc = (crc >> 8) ^ table[index]
        }
        return crc ^ 0xFFFF_FFFF
    }
}
