//
//  MirageQualityTestProtocol.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/2/26.
//
//  UDP packet format for quality tests.
//

import Foundation

package let mirageQualityTestMagic: UInt32 = 0x4D49_5251 // "MIRQ"
package let mirageQualityTestVersion: UInt8 = 1
package let mirageQualityTestHeaderSize: Int = 37

package struct QualityTestPacketHeader {
    package let testID: UUID
    package let stageID: UInt16
    package let sequenceNumber: UInt32
    package let timestampNs: UInt64
    package let payloadLength: UInt16

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

    package static func deserialize(from data: Data) -> QualityTestPacketHeader? {
        guard data.count >= mirageQualityTestHeaderSize else { return nil }
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

        let magic = read(UInt32.self)
        guard magic == mirageQualityTestMagic else { return nil }
        let version = readByte()
        guard version == mirageQualityTestVersion else { return nil }
        let stageID = read(UInt16.self)
        let sequenceNumber = read(UInt32.self)
        let timestampNs = read(UInt64.self)
        let uuidBytes: uuid_t = data.withUnsafeBytes { ptr in
            ptr.loadUnaligned(fromByteOffset: offset, as: uuid_t.self)
        }
        let testID = UUID(uuid: uuidBytes)
        offset += 16
        let payloadLength = read(UInt16.self)

        return QualityTestPacketHeader(
            testID: testID,
            stageID: stageID,
            sequenceNumber: sequenceNumber,
            timestampNs: timestampNs,
            payloadLength: payloadLength
        )
    }
}
