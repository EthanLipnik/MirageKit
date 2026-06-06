//
//  MirageMosaicPacketHeader.swift
//  MirageWire
//
//  Created by Ethan Lipnik on 6/6/26.
//

import Foundation
import MirageCore

/// Magic number for Mosaic media-unit packets: "MIMU".
package let mirageMosaicMediaMagic: UInt32 = 0x4D49_4D55

package let mirageMosaicHeaderSize: Int =
    4 + // magic
    4 + // version
    2 + // flags
    2 + // streamID
    4 + // packetSequence
    8 + // timestamp
    4 + // tilePlanEpoch
    4 + // mediaEpoch
    2 + // mediaUnitIndex
    2 + // tileIndex
    2 + // transportGroupIndex
    2 + // presentationGroupIndex
    4 + // unitFrameNumber
    4 + // tileVersion
    4 + // dependencyVersion
    2 + // fragmentIndex
    2 + // fragmentCount
    1 + // fecBlockSize
    4 + // payloadLength
    4 + // unitByteCount
    4 // checksum

package func mirageMosaicPayloadSize(maxPacketSize: Int) -> Int {
    let payload = maxPacketSize - mirageMosaicHeaderSize - mirageMediaAuthTagSize
    if payload > 0 { return payload }
    return mirageDefaultMaxPacketSize - mirageMosaicHeaderSize - mirageMediaAuthTagSize
}

package struct MirageMosaicPacketHeader: Equatable, Sendable {
    package var magic: UInt32 = mirageMosaicMediaMagic
    package var version: UInt32 = MirageWireProtocol.currentMediaPacketVersion
    package var flags: MirageMosaicPacketFlags
    package var streamID: StreamID
    package var packetSequence: UInt32
    package var timestamp: UInt64
    package var tilePlanEpoch: UInt32
    package var mediaEpoch: UInt32
    package var mediaUnitIndex: UInt16
    package var tileIndex: UInt16
    package var transportGroupIndex: UInt16
    package var presentationGroupIndex: UInt16
    package var unitFrameNumber: UInt32
    package var tileVersion: UInt32
    package var dependencyVersion: UInt32
    package var fragmentIndex: UInt16
    package var fragmentCount: UInt16
    package var fecBlockSize: UInt8
    package var payloadLength: UInt32
    package var unitByteCount: UInt32
    package var checksum: UInt32

    package init(
        flags: MirageMosaicPacketFlags = [],
        streamID: StreamID,
        packetSequence: UInt32,
        timestamp: UInt64,
        tilePlanEpoch: UInt32,
        mediaEpoch: UInt32,
        mediaUnitIndex: UInt16,
        tileIndex: UInt16,
        transportGroupIndex: UInt16,
        presentationGroupIndex: UInt16,
        unitFrameNumber: UInt32,
        tileVersion: UInt32,
        dependencyVersion: UInt32,
        fragmentIndex: UInt16,
        fragmentCount: UInt16,
        fecBlockSize: UInt8 = 0,
        payloadLength: UInt32,
        unitByteCount: UInt32,
        checksum: UInt32
    ) {
        self.flags = flags
        self.streamID = streamID
        self.packetSequence = packetSequence
        self.timestamp = timestamp
        self.tilePlanEpoch = tilePlanEpoch
        self.mediaEpoch = mediaEpoch
        self.mediaUnitIndex = mediaUnitIndex
        self.tileIndex = tileIndex
        self.transportGroupIndex = transportGroupIndex
        self.presentationGroupIndex = presentationGroupIndex
        self.unitFrameNumber = unitFrameNumber
        self.tileVersion = tileVersion
        self.dependencyVersion = dependencyVersion
        self.fragmentIndex = fragmentIndex
        self.fragmentCount = fragmentCount
        self.fecBlockSize = fecBlockSize
        self.payloadLength = payloadLength
        self.unitByteCount = unitByteCount
        self.checksum = checksum
    }

    package func serialize() -> Data {
        var data = Data(capacity: mirageMosaicHeaderSize)
        withUnsafeBytes(of: magic.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: version.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: flags.rawValue.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: streamID.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: packetSequence.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: timestamp.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: tilePlanEpoch.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: mediaEpoch.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: mediaUnitIndex.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: tileIndex.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: transportGroupIndex.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: presentationGroupIndex.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: unitFrameNumber.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: tileVersion.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: dependencyVersion.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: fragmentIndex.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: fragmentCount.littleEndian) { data.append(contentsOf: $0) }
        data.append(fecBlockSize)
        withUnsafeBytes(of: payloadLength.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: unitByteCount.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: checksum.littleEndian) { data.append(contentsOf: $0) }
        return data
    }

    package static func deserialize(from data: Data) -> MirageMosaicPacketHeader? {
        guard data.count >= mirageMosaicHeaderSize else { return nil }
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
        guard magic == mirageMosaicMediaMagic else { return nil }
        let version: UInt32 = read()
        guard version == MirageWireProtocol.currentMediaPacketVersion else { return nil }

        return MirageMosaicPacketHeader(
            flags: MirageMosaicPacketFlags(rawValue: read()),
            streamID: read(),
            packetSequence: read(),
            timestamp: read(),
            tilePlanEpoch: read(),
            mediaEpoch: read(),
            mediaUnitIndex: read(),
            tileIndex: read(),
            transportGroupIndex: read(),
            presentationGroupIndex: read(),
            unitFrameNumber: read(),
            tileVersion: read(),
            dependencyVersion: read(),
            fragmentIndex: read(),
            fragmentCount: read(),
            fecBlockSize: readByte(),
            payloadLength: read(),
            unitByteCount: read(),
            checksum: read()
        )
    }
}

package struct MirageMosaicPacketFlags: OptionSet, Sendable, Equatable {
    package let rawValue: UInt16

    package init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    package static let keyframe = MirageMosaicPacketFlags(rawValue: 1 << 0)
    package static let endOfUnit = MirageMosaicPacketFlags(rawValue: 1 << 1)
    package static let parameterSet = MirageMosaicPacketFlags(rawValue: 1 << 2)
    package static let discontinuity = MirageMosaicPacketFlags(rawValue: 1 << 3)
    package static let priority = MirageMosaicPacketFlags(rawValue: 1 << 4)
    package static let atomicGroup = MirageMosaicPacketFlags(rawValue: 1 << 5)
    package static let retainedTransform = MirageMosaicPacketFlags(rawValue: 1 << 6)
    package static let fecParity = MirageMosaicPacketFlags(rawValue: 1 << 10)
    package static let encryptedPayload = MirageMosaicPacketFlags(rawValue: 1 << 11)
    package static let proResCodec = MirageMosaicPacketFlags(rawValue: 1 << 12)
}

