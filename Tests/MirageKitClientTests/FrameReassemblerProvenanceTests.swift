//
//  FrameReassemblerProvenanceTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/8/26.
//

@testable import MirageKit
@testable import MirageKitClient
import CoreGraphics
import Foundation
import Testing

@Suite("Frame Reassembler Provenance")
struct FrameReassemblerProvenanceTests {
    @Test("Epoch and dimension token survive frame reassembly")
    func epochAndDimensionTokenSurviveFrameReassembly() {
        let reassembler = FrameReassembler(streamID: 77, maxPayloadSize: 128)
        let delivered = LockedFrameProvenance()
        let payload = Data([1, 2, 3, 4])

        reassembler.setFrameHandler { _, data, isKeyframe, frameNumber, timestamp, epoch, dimensionToken, contentRect, release in
            delivered.record(
                data: data,
                isKeyframe: isKeyframe,
                frameNumber: frameNumber,
                timestamp: timestamp,
                epoch: epoch,
                dimensionToken: dimensionToken,
                contentRect: contentRect
            )
            release()
        }

        reassembler.processPacket(
            payload,
            header: makeHeader(
                streamID: 77,
                flags: [.keyframe],
                frameNumber: 5,
                payload: payload,
                timestamp: 123,
                dimensionToken: 42,
                epoch: 7
            )
        )

        #expect(delivered.data == payload)
        #expect(delivered.isKeyframe == true)
        #expect(delivered.frameNumber == 5)
        #expect(delivered.timestamp == 123)
        #expect(delivered.epoch == 7)
        #expect(delivered.dimensionToken == 42)
        #expect(delivered.contentRect == CGRect(x: 1, y: 2, width: 3, height: 4))
    }

    @Test("Mixed dimension token fragments cannot complete one frame")
    func mixedDimensionTokenFragmentsCannotCompleteOneFrame() {
        let reassembler = FrameReassembler(streamID: 78, maxPayloadSize: 2)
        let delivered = LockedFrameProvenance()
        let first = Data([1, 2])
        let second = Data([3, 4])

        reassembler.updateExpectedDimensionToken(42)
        reassembler.setFrameHandler { _, data, isKeyframe, frameNumber, timestamp, epoch, dimensionToken, contentRect, release in
            delivered.record(
                data: data,
                isKeyframe: isKeyframe,
                frameNumber: frameNumber,
                timestamp: timestamp,
                epoch: epoch,
                dimensionToken: dimensionToken,
                contentRect: contentRect
            )
            release()
        }

        reassembler.processPacket(
            first,
            header: makeHeader(
                streamID: 78,
                flags: [.keyframe],
                frameNumber: 1,
                payload: first,
                fragmentIndex: 0,
                fragmentCount: 2,
                frameByteCount: 4,
                dimensionToken: 42,
                epoch: 1
            )
        )
        reassembler.processPacket(
            second,
            header: makeHeader(
                streamID: 78,
                flags: [.keyframe],
                frameNumber: 1,
                payload: second,
                fragmentIndex: 1,
                fragmentCount: 2,
                frameByteCount: 4,
                dimensionToken: 43,
                epoch: 1
            )
        )

        #expect(delivered.data == nil)
    }

    private func makeHeader(
        streamID: StreamID,
        flags: FrameFlags,
        frameNumber: UInt32,
        payload: Data,
        timestamp: UInt64 = 0,
        fragmentIndex: UInt16 = 0,
        fragmentCount: UInt16 = 1,
        frameByteCount: UInt32? = nil,
        dimensionToken: UInt16,
        epoch: UInt16
    ) -> FrameHeader {
        FrameHeader(
            flags: flags,
            streamID: streamID,
            sequenceNumber: frameNumber,
            timestamp: timestamp,
            frameNumber: frameNumber,
            fragmentIndex: fragmentIndex,
            fragmentCount: fragmentCount,
            payloadLength: UInt32(payload.count),
            frameByteCount: frameByteCount ?? UInt32(payload.count),
            checksum: CRC32.calculate(payload),
            contentRect: CGRect(x: 1, y: 2, width: 3, height: 4),
            dimensionToken: dimensionToken,
            epoch: epoch
        )
    }
}

private final class LockedFrameProvenance: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: (
        data: Data,
        isKeyframe: Bool,
        frameNumber: UInt32,
        timestamp: UInt64,
        epoch: UInt16,
        dimensionToken: UInt16,
        contentRect: CGRect
    )?

    var data: Data? {
        lock.lock()
        defer { lock.unlock() }
        return storage?.data
    }

    var isKeyframe: Bool? {
        lock.lock()
        defer { lock.unlock() }
        return storage?.isKeyframe
    }

    var frameNumber: UInt32? {
        lock.lock()
        defer { lock.unlock() }
        return storage?.frameNumber
    }

    var timestamp: UInt64? {
        lock.lock()
        defer { lock.unlock() }
        return storage?.timestamp
    }

    var epoch: UInt16? {
        lock.lock()
        defer { lock.unlock() }
        return storage?.epoch
    }

    var dimensionToken: UInt16? {
        lock.lock()
        defer { lock.unlock() }
        return storage?.dimensionToken
    }

    var contentRect: CGRect? {
        lock.lock()
        defer { lock.unlock() }
        return storage?.contentRect
    }

    func record(
        data: Data,
        isKeyframe: Bool,
        frameNumber: UInt32,
        timestamp: UInt64,
        epoch: UInt16,
        dimensionToken: UInt16,
        contentRect: CGRect
    ) {
        lock.lock()
        storage = (
            data: data,
            isKeyframe: isKeyframe,
            frameNumber: frameNumber,
            timestamp: timestamp,
            epoch: epoch,
            dimensionToken: dimensionToken,
            contentRect: contentRect
        )
        lock.unlock()
    }
}
