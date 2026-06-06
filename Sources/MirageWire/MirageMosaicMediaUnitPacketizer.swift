//
//  MirageMosaicMediaUnitPacketizer.swift
//  MirageWire
//
//  Created by Ethan Lipnik on 6/6/26.
//

import Foundation
import MirageCore

package struct MirageMosaicMediaUnitPacketizerInput: Sendable, Equatable {
    package let streamID: StreamID
    package let packetSequenceStart: UInt32
    package let timestamp: UInt64
    package let tilePlanEpoch: UInt32
    package let mediaEpoch: UInt32
    package let mediaUnitIndex: UInt16
    package let tileIndex: UInt16
    package let transportGroupIndex: UInt16
    package let presentationGroupIndex: UInt16
    package let unitFrameNumber: UInt32
    package let tileVersion: UInt32
    package let dependencyVersion: UInt32
    package let isKeyframe: Bool
    package let isAtomicGroup: Bool
    package let payload: Data
    package let maximumPayloadBytes: Int

    package init(
        streamID: StreamID,
        packetSequenceStart: UInt32,
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
        isKeyframe: Bool,
        isAtomicGroup: Bool,
        payload: Data,
        maximumPayloadBytes: Int
    ) {
        self.streamID = streamID
        self.packetSequenceStart = packetSequenceStart
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
        self.isKeyframe = isKeyframe
        self.isAtomicGroup = isAtomicGroup
        self.payload = payload
        self.maximumPayloadBytes = max(1, maximumPayloadBytes)
    }
}

package struct MirageMosaicMediaUnitPacketizer {
    package static func packetize(_ input: MirageMosaicMediaUnitPacketizerInput) -> [Data] {
        guard !input.payload.isEmpty else { return [] }
        let fragmentCount = Int(ceil(Double(input.payload.count) / Double(input.maximumPayloadBytes)))
        guard fragmentCount > 0, fragmentCount <= Int(UInt16.max) else { return [] }

        return (0 ..< fragmentCount).map { fragmentIndex in
            let start = fragmentIndex * input.maximumPayloadBytes
            let end = min(start + input.maximumPayloadBytes, input.payload.count)
            let fragmentPayload = Data(input.payload[start ..< end])
            var flags: MirageMosaicPacketFlags = []
            if input.isKeyframe {
                flags.insert(.keyframe)
                if fragmentIndex == 0 { flags.insert(.parameterSet) }
            }
            if input.isAtomicGroup { flags.insert(.atomicGroup) }
            if fragmentIndex == fragmentCount - 1 { flags.insert(.endOfUnit) }

            let header = MirageMosaicPacketHeader(
                flags: flags,
                streamID: input.streamID,
                packetSequence: input.packetSequenceStart + UInt32(fragmentIndex),
                timestamp: input.timestamp,
                tilePlanEpoch: input.tilePlanEpoch,
                mediaEpoch: input.mediaEpoch,
                mediaUnitIndex: input.mediaUnitIndex,
                tileIndex: input.tileIndex,
                transportGroupIndex: input.transportGroupIndex,
                presentationGroupIndex: input.presentationGroupIndex,
                unitFrameNumber: input.unitFrameNumber,
                tileVersion: input.tileVersion,
                dependencyVersion: input.dependencyVersion,
                fragmentIndex: UInt16(fragmentIndex),
                fragmentCount: UInt16(fragmentCount),
                payloadLength: UInt32(fragmentPayload.count),
                unitByteCount: UInt32(input.payload.count),
                checksum: CRC32.calculate(fragmentPayload)
            )

            var packet = header.serialize()
            packet.append(fragmentPayload)
            return packet
        }
    }
}

