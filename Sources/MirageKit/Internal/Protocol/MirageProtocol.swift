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

/// Protocol version
package let mirageProtocolVersion: UInt8 = 1

/// Default maximum UDP packet size (header + payload) to avoid IPv6 fragmentation.
/// 1200 bytes keeps packets under the IPv6 minimum MTU (1280) once IP/UDP headers are added.
public let mirageDefaultMaxPacketSize: Int = 1200

// swiftlint:disable identifier_name
@available(*, deprecated, renamed: "mirageDefaultMaxPacketSize")
public let MirageDefaultMaxPacketSize: Int = mirageDefaultMaxPacketSize
// swiftlint:enable identifier_name

/// Header size in bytes:
/// Base fields (4+1+2+2+4+8+4+2+2+4+4+4 = 41) +
/// contentRect (4 x Float32 = 16) +
/// dimensionToken (UInt16 = 2) +
/// epoch (UInt16 = 2) = 61 total
package let mirageHeaderSize: Int = 61

/// Compute payload size from the configured maximum packet size.
/// `maxPacketSize` includes the Mirage header; this returns the payload size only.
package func miragePayloadSize(maxPacketSize: Int) -> Int {
    let payload = maxPacketSize - mirageHeaderSize
    if payload > 0 { return payload }
    return mirageDefaultMaxPacketSize - mirageHeaderSize
}

/// Video frame packet header (61 bytes, fixed size)
package struct FrameHeader {
    /// Magic number for validation (0x4D495247 = "MIRG")
    package var magic: UInt32 = mirageProtocolMagic

    /// Protocol version
    package var version: UInt8 = mirageProtocolVersion

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

    /// Payload length in bytes
    package var payloadLength: UInt32

    /// Total encoded frame length in bytes (data only, excludes parity)
    package var frameByteCount: UInt32

    /// CRC32 checksum of payload
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

    /// Get contentRect as CGRect
    package var contentRect: CGRect {
        CGRect(
            x: CGFloat(contentRectX),
            y: CGFloat(contentRectY),
            width: CGFloat(contentRectWidth),
            height: CGFloat(contentRectHeight)
        )
    }

    /// Serialize header to bytes
    package func serialize() -> Data {
        var data = Data(capacity: mirageHeaderSize)

        withUnsafeBytes(of: magic.littleEndian) { data.append(contentsOf: $0) }
        data.append(version)
        withUnsafeBytes(of: flags.rawValue.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: streamID.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: sequenceNumber.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: timestamp.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: frameNumber.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: fragmentIndex.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: fragmentCount.littleEndian) { data.append(contentsOf: $0) }
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

        func write<T: FixedWidthInteger>(_ value: T) {
            buffer.storeBytes(of: value.littleEndian, toByteOffset: offset, as: T.self)
            offset += MemoryLayout<T>.size
        }

        func writeByte(_ value: UInt8) {
            buffer.storeBytes(of: value, toByteOffset: offset, as: UInt8.self)
            offset += 1
        }

        func writeFloat32(_ value: Float32) {
            write(value.bitPattern)
        }

        write(magic)
        writeByte(version)
        write(flags.rawValue)
        write(streamID)
        write(sequenceNumber)
        write(timestamp)
        write(frameNumber)
        write(fragmentIndex)
        write(fragmentCount)
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

    /// Deserialize header from bytes
    package static func deserialize(from data: Data) -> FrameHeader? {
        guard data.count >= mirageHeaderSize else { return nil }

        var offset = 0

        func read<T: FixedWidthInteger>(_: T.Type) -> T {
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
            let bits = read(UInt32.self)
            return Float32(bitPattern: bits)
        }

        let magic = read(UInt32.self)
        guard magic == mirageProtocolMagic else { return nil }

        let version = readByte()
        guard version == mirageProtocolVersion else { return nil }

        let flagsRaw = read(UInt16.self)
        let flags = FrameFlags(rawValue: flagsRaw)
        let streamID = read(UInt16.self)
        let sequenceNumber = read(UInt32.self)
        let timestamp = read(UInt64.self)
        let frameNumber = read(UInt32.self)
        let fragmentIndex = read(UInt16.self)
        let fragmentCount = read(UInt16.self)
        let payloadLength = read(UInt32.self)
        let frameByteCount = read(UInt32.self)
        let checksum = read(UInt32.self)
        let contentRectX = readFloat32()
        let contentRectY = readFloat32()
        let contentRectWidth = readFloat32()
        let contentRectHeight = readFloat32()

        // Dimension token
        let dimensionToken = read(UInt16.self)

        // Epoch
        let epoch = read(UInt16.self)

        return FrameHeader(
            flags: flags,
            streamID: streamID,
            sequenceNumber: sequenceNumber,
            timestamp: timestamp,
            frameNumber: frameNumber,
            fragmentIndex: fragmentIndex,
            fragmentCount: fragmentCount,
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

    /// High priority packet (for QoS)
    package static let priority = FrameFlags(rawValue: 1 << 4)

    /// This is a login/lock screen display stream (not a window stream)
    /// Used when host is locked and streaming the virtual display for remote unlock
    package static let loginDisplay = FrameFlags(rawValue: 1 << 7)

    /// This is a full desktop stream (virtual display mirroring mode)
    /// Used when client requests streaming of the entire desktop
    package static let desktopStream = FrameFlags(rawValue: 1 << 8)

    /// Frame is a repeat of the most recent capture
    package static let repeatedFrame = FrameFlags(rawValue: 1 << 9)

    /// FEC parity fragment (not part of the encoded frame payload)
    package static let fecParity = FrameFlags(rawValue: 1 << 10)
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
