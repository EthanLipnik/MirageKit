//
//  AudioDecodePipelineTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/4/26.
//
//  Off-main client audio decode pipeline coverage.
//

@testable import MirageKitClient
import Foundation
import MirageKit
import Testing

@Suite("Client Audio Decode Pipeline")
struct AudioDecodePipelineTests {
    @Test("Ingest preserves timestamp ordering across out-of-order packets")
    func preservesTimestampOrdering() async {
        let pipeline = ClientAudioDecodePipeline(startupBufferSeconds: 0.150)
        let payload = Self.makePCM16StereoPayload(sampleCount: 4_800)

        let newer = Self.makeHeader(
            frameNumber: 20,
            timestamp: 2_000,
            payloadSize: payload.count
        )
        let older = Self.makeHeader(
            frameNumber: 19,
            timestamp: 1_000,
            payloadSize: payload.count
        )

        let firstBatch = await pipeline.ingestPacket(
            header: newer,
            payload: payload,
            targetChannelCount: 2
        )
        #expect(firstBatch.isEmpty)

        let secondBatch = await pipeline.ingestPacket(
            header: older,
            payload: payload,
            targetChannelCount: 2
        )
        #expect(secondBatch.count == 2)
        #expect(secondBatch[0].timestampNs == 1_000)
        #expect(secondBatch[1].timestampNs == 2_000)
    }

    @Test("Ingest emits decoded frames only when a full frame is assembled")
    func emitsDecodedFramesOnlyAfterFullAssembly() async {
        let pipeline = ClientAudioDecodePipeline(startupBufferSeconds: 0)
        let fragmentPayload = Data(repeating: 0x12, count: 960)

        let firstFragment = Self.makeHeader(
            frameNumber: 44,
            timestamp: 4_400,
            fragmentIndex: 0,
            fragmentCount: 2,
            payloadSize: fragmentPayload.count,
            frameByteCount: fragmentPayload.count * 2
        )
        let secondFragment = Self.makeHeader(
            frameNumber: 44,
            timestamp: 4_400,
            fragmentIndex: 1,
            fragmentCount: 2,
            payloadSize: fragmentPayload.count,
            frameByteCount: fragmentPayload.count * 2
        )

        let firstBatch = await pipeline.ingestPacket(
            header: firstFragment,
            payload: fragmentPayload,
            targetChannelCount: 2
        )
        #expect(firstBatch.isEmpty)

        let secondBatch = await pipeline.ingestPacket(
            header: secondFragment,
            payload: fragmentPayload,
            targetChannelCount: 2
        )
        #expect(secondBatch.count == 1)
        #expect(secondBatch[0].frameCount > 0)
    }

    @Test("Reset drops buffered state and decodes subsequent packets cleanly")
    func resetDropsBufferedState() async {
        let pipeline = ClientAudioDecodePipeline(startupBufferSeconds: 0.150)
        let payload = Self.makePCM16StereoPayload(sampleCount: 4_800)
        let header = Self.makeHeader(frameNumber: 10, timestamp: 1_000, payloadSize: payload.count)

        let initialBatch = await pipeline.ingestPacket(
            header: header,
            payload: payload,
            targetChannelCount: 2
        )
        #expect(initialBatch.isEmpty)

        await pipeline.reset()

        let afterResetBatch = await pipeline.ingestPacket(
            header: header,
            payload: payload,
            targetChannelCount: 2
        )
        #expect(afterResetBatch.isEmpty)
    }

    private static func makeHeader(
        frameNumber: UInt32,
        timestamp: UInt64,
        fragmentIndex: UInt16 = 0,
        fragmentCount: UInt16 = 1,
        payloadSize: Int,
        frameByteCount: Int? = nil
    ) -> AudioPacketHeader {
        AudioPacketHeader(
            codec: .pcm16LE,
            streamID: 7,
            sequenceNumber: frameNumber,
            timestamp: timestamp,
            frameNumber: frameNumber,
            fragmentIndex: fragmentIndex,
            fragmentCount: fragmentCount,
            payloadLength: UInt16(payloadSize),
            frameByteCount: UInt32(frameByteCount ?? payloadSize),
            sampleRate: 48_000,
            channelCount: 2,
            samplesPerFrame: 4_800,
            checksum: 0
        )
    }

    private static func makePCM16StereoPayload(sampleCount: Int) -> Data {
        let clampedSampleCount = max(1, sampleCount)
        var payload = Data()
        payload.reserveCapacity(clampedSampleCount * 2 * MemoryLayout<Int16>.size)
        for sampleIndex in 0 ..< clampedSampleCount {
            var left = Int16((sampleIndex % 255) - 127).littleEndian
            var right = Int16(127 - (sampleIndex % 255)).littleEndian
            withUnsafeBytes(of: &left) { payload.append(contentsOf: $0) }
            withUnsafeBytes(of: &right) { payload.append(contentsOf: $0) }
        }
        return payload
    }
}
