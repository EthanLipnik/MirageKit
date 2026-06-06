//
//  StreamControllerMosaicMediaUnitReassembler.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 6/6/26.
//

import Foundation
import MirageCore
import MirageWire

final class StreamControllerMosaicMediaUnitReassembler: @unchecked Sendable {
    struct CompletedUnit: Sendable, Equatable {
        let streamID: StreamID
        let timestamp: UInt64
        let tilePlanEpoch: UInt32
        let mediaEpoch: UInt32
        let mediaUnitIndex: UInt16
        let tileIndex: UInt16
        let transportGroupIndex: UInt16
        let presentationGroupIndex: UInt16
        let unitFrameNumber: UInt32
        let tileVersion: UInt32
        let dependencyVersion: UInt32
        let isKeyframe: Bool
        let isAtomicGroup: Bool
        let payload: Data
    }

    private struct PendingUnitKey: Hashable {
        let tilePlanEpoch: UInt32
        let mediaEpoch: UInt32
        let mediaUnitIndex: UInt16
        let unitFrameNumber: UInt32
    }

    private struct PendingUnit {
        let header: MirageMosaicPacketHeader
        var fragments: [UInt16: Data] = [:]

        var isComplete: Bool {
            fragments.count == Int(header.fragmentCount)
        }

        func assembledPayload() -> Data? {
            guard isComplete else { return nil }
            var payload = Data(capacity: Int(header.unitByteCount))
            for index in 0 ..< header.fragmentCount {
                guard let fragment = fragments[index] else { return nil }
                payload.append(fragment)
            }
            guard payload.count == Int(header.unitByteCount) else { return nil }
            return payload
        }
    }

    private let streamID: StreamID
    private let lock = NSLock()
    private var pendingUnits: [PendingUnitKey: PendingUnit] = [:]

    init(streamID: StreamID) {
        self.streamID = streamID
    }

    func processPacket(_ packet: Data) -> CompletedUnit? {
        lock.lock()
        defer { lock.unlock() }

        guard let header = MirageMosaicPacketHeader.deserialize(from: packet),
              header.streamID == streamID,
              header.fragmentCount > 0,
              header.fragmentIndex < header.fragmentCount else {
            return nil
        }

        let payload = Data(packet.dropFirst(MirageWire.mirageMosaicHeaderSize))
        guard payload.count == Int(header.payloadLength),
              MirageWire.CRC32.calculate(payload) == header.checksum else {
            return nil
        }

        let key = PendingUnitKey(
            tilePlanEpoch: header.tilePlanEpoch,
            mediaEpoch: header.mediaEpoch,
            mediaUnitIndex: header.mediaUnitIndex,
            unitFrameNumber: header.unitFrameNumber
        )
        var pending = pendingUnits[key] ?? PendingUnit(header: header)
        pending.fragments[header.fragmentIndex] = payload
        pendingUnits[key] = pending

        guard let assembledPayload = pending.assembledPayload() else { return nil }
        pendingUnits.removeValue(forKey: key)
        return CompletedUnit(
            streamID: header.streamID,
            timestamp: header.timestamp,
            tilePlanEpoch: header.tilePlanEpoch,
            mediaEpoch: header.mediaEpoch,
            mediaUnitIndex: header.mediaUnitIndex,
            tileIndex: header.tileIndex,
            transportGroupIndex: header.transportGroupIndex,
            presentationGroupIndex: header.presentationGroupIndex,
            unitFrameNumber: header.unitFrameNumber,
            tileVersion: header.tileVersion,
            dependencyVersion: header.dependencyVersion,
            isKeyframe: header.flags.contains(.keyframe),
            isAtomicGroup: header.flags.contains(.atomicGroup),
            payload: assembledPayload
        )
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        pendingUnits.removeAll()
    }
}
