//
//  AudioJitterBufferTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/6/26.
//
//  Audio packet reordering and buffering coverage.
//

@testable import MirageKitClient
import MirageKit
import Testing

@Suite("Audio Jitter Buffer")
struct AudioJitterBufferTests {
    @Test("Startup buffer holds frames until target duration")
    func startupBufferThreshold() async {
        let buffer = AudioJitterBuffer(startupBufferSeconds: 0.150)

        let firstHeader = makeHeader(frameNumber: 1, timestamp: 100, samplesPerFrame: 4_800)
        let secondHeader = makeHeader(frameNumber: 2, timestamp: 200, samplesPerFrame: 4_800)
        let payload = Data(repeating: 0x11, count: 32)

        let firstFrames = await buffer.ingest(header: firstHeader, payload: payload)
        #expect(firstFrames.isEmpty)

        let secondFrames = await buffer.ingest(header: secondHeader, payload: payload)
        #expect(secondFrames.count == 2)
        #expect(secondFrames[0].frameNumber == 1)
        #expect(secondFrames[1].frameNumber == 2)
    }

    @Test("Out-of-order packets are emitted in timestamp order")
    func outOfOrderAssembly() async {
        let buffer = AudioJitterBuffer(startupBufferSeconds: 0.150)
        let payload = Data(repeating: 0x44, count: 48)

        let newerFrame = makeHeader(frameNumber: 9, timestamp: 9_000, samplesPerFrame: 4_800)
        let olderFrame = makeHeader(frameNumber: 8, timestamp: 8_000, samplesPerFrame: 4_800)

        let firstResult = await buffer.ingest(header: newerFrame, payload: payload)
        #expect(firstResult.isEmpty)

        let secondResult = await buffer.ingest(header: olderFrame, payload: payload)
        #expect(secondResult.count == 2)
        #expect(secondResult[0].timestampNs == 8_000)
        #expect(secondResult[1].timestampNs == 9_000)
    }

    @Test("Discontinuity clears pending fragments")
    func discontinuityClearsPendingState() async {
        let buffer = AudioJitterBuffer(startupBufferSeconds: 0)

        let fragmentedHeader = makeHeader(
            frameNumber: 30,
            timestamp: 30_000,
            fragmentIndex: 0,
            fragmentCount: 2
        )
        await buffer.ingest(header: fragmentedHeader, payload: Data(repeating: 0xAA, count: 16))

        var discontinuityHeader = makeHeader(
            frameNumber: 31,
            timestamp: 31_000,
            samplesPerFrame: 7_200
        )
        discontinuityHeader.flags = [.discontinuity]

        let result = await buffer.ingest(header: discontinuityHeader, payload: Data(repeating: 0xBB, count: 24))
        #expect(result.count == 1)
        #expect(result[0].frameNumber == 31)
    }

    private func makeHeader(
        frameNumber: UInt32,
        timestamp: UInt64,
        fragmentIndex: UInt16 = 0,
        fragmentCount: UInt16 = 1,
        samplesPerFrame: UInt16 = 960
    ) -> AudioPacketHeader {
        AudioPacketHeader(
            codec: .aacLC,
            streamID: 5,
            sequenceNumber: frameNumber,
            timestamp: timestamp,
            frameNumber: frameNumber,
            fragmentIndex: fragmentIndex,
            fragmentCount: fragmentCount,
            payloadLength: 32,
            frameByteCount: 32,
            sampleRate: 48_000,
            channelCount: 2,
            samplesPerFrame: samplesPerFrame,
            checksum: 0
        )
    }
}

