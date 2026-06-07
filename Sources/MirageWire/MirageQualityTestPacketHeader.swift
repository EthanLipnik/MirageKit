//
//  MirageQualityTestPacketHeader.swift
//  MirageWire
//
//  Created by Ethan Lipnik on 6/5/26.
//
//  UDP packet format for quality tests.
//

import Foundation

/// Magic prefix for Mirage quality-test datagrams (`MIRQ`).
package let mirageQualityTestMagic: UInt32 = 0x4D49_5251
/// Binary packet-header version.
package let mirageQualityTestVersion: UInt8 = 1
/// Serialized byte count for ``QualityTestPacketHeader``.
package let mirageQualityTestHeaderSize =
    MemoryLayout<UInt32>.size +
    MemoryLayout<UInt8>.size +
    MemoryLayout<UInt16>.size +
    MemoryLayout<UInt32>.size +
    MemoryLayout<UInt64>.size +
    MemoryLayout<uuid_t>.size +
    MemoryLayout<UInt16>.size

/// Fixed-width binary header that prefixes every quality-test datagram.
package struct QualityTestPacketHeader {
    /// Test run identifier shared with control-channel quality-test messages.
    package let testID: UUID
    /// Stage identifier from the active ``MirageDiagnostics.MirageQualityTestPlan``.
    package let stageID: UInt16
    /// Monotonic packet sequence within the stage.
    package let sequenceNumber: UInt32
    /// Host send timestamp in nanoseconds.
    package let timestampNs: UInt64
    /// Payload byte count following the header.
    package let payloadLength: UInt16

    /// Creates a quality-test packet header.
    package init(
        testID: UUID,
        stageID: UInt16,
        sequenceNumber: UInt32,
        timestampNs: UInt64,
        payloadLength: UInt16
    ) {
        self.testID = testID
        self.stageID = stageID
        self.sequenceNumber = sequenceNumber
        self.timestampNs = timestampNs
        self.payloadLength = payloadLength
    }

    /// Serializes the header in little-endian wire order.
    package func serialize() -> Data {
        var data = Data(capacity: mirageQualityTestHeaderSize)
        withUnsafeBytes(of: mirageQualityTestMagic.littleEndian) { data.append(contentsOf: $0) }
        data.append(mirageQualityTestVersion)
        withUnsafeBytes(of: stageID.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: sequenceNumber.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: timestampNs.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: testID.uuid) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: payloadLength.littleEndian) { data.append(contentsOf: $0) }
        return data
    }

    /// Deserializes a packet header and rejects unknown magic or version values.
    package static func deserialize(from data: Data) -> QualityTestPacketHeader? {
        guard data.count >= mirageQualityTestHeaderSize else { return nil }
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
        guard magic == mirageQualityTestMagic else { return nil }
        let version = readByte()
        guard version == mirageQualityTestVersion else { return nil }
        let stageID: UInt16 = read()
        let sequenceNumber: UInt32 = read()
        let timestampNs: UInt64 = read()
        let uuidBytes: uuid_t = data.withUnsafeBytes { ptr in
            ptr.loadUnaligned(fromByteOffset: offset, as: uuid_t.self)
        }
        let testID = UUID(uuid: uuidBytes)
        offset += 16
        let payloadLength: UInt16 = read()

        return QualityTestPacketHeader(
            testID: testID,
            stageID: stageID,
            sequenceNumber: sequenceNumber,
            timestampNs: timestampNs,
            payloadLength: payloadLength
        )
    }
}
