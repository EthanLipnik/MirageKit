//
//  MirageMediaPathProbeProtocol.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/15/26.
//

import Foundation

/// Magic bytes "MIRP" (0x4D495250) identifying media path probe packets.
package let mirageMediaPathProbeMagic: UInt32 = 0x4D49_5250

/// Lightweight probe packet echoed by the host to measure per-interface RTT.
///
/// Wire format (16 bytes, little-endian):
/// - [0..3]   magic      (UInt32) — 0x4D495250 "MIRP"
/// - [4..7]   sequence   (UInt32) — Probe sequence number
/// - [8..15]  timestampNs(UInt64) — Client monotonic timestamp in nanoseconds
package struct MirageMediaPathProbePacket: Sendable {
    package static let packetSize = 16

    package let sequenceNumber: UInt32
    package let timestampNs: UInt64

    package init(sequenceNumber: UInt32, timestampNs: UInt64) {
        self.sequenceNumber = sequenceNumber
        self.timestampNs = timestampNs
    }

    package func serialize() -> Data {
        var data = Data(capacity: Self.packetSize)
        var magic = mirageMediaPathProbeMagic.littleEndian
        var seq = sequenceNumber.littleEndian
        var ts = timestampNs.littleEndian
        data.append(contentsOf: withUnsafeBytes(of: &magic) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: &seq) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: &ts) { Array($0) })
        return data
    }

    package static func deserialize(from data: Data) throws -> MirageMediaPathProbePacket {
        guard data.count >= packetSize else {
            throw MirageError.protocolError("Probe packet too short (\(data.count) < \(packetSize))")
        }
        let magic: UInt32 = data.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self)
        }
        guard UInt32(littleEndian: magic) == mirageMediaPathProbeMagic else {
            throw MirageError.protocolError("Invalid probe packet magic")
        }
        let seq: UInt32 = data.withUnsafeBytes {
            UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self))
        }
        let ts: UInt64 = data.withUnsafeBytes {
            UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: 8, as: UInt64.self))
        }
        return MirageMediaPathProbePacket(sequenceNumber: seq, timestampNs: ts)
    }
}
