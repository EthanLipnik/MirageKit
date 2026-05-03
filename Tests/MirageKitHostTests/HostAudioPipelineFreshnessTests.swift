//
//  HostAudioPipelineFreshnessTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/3/26.
//
//  Host audio freshness and discontinuity coverage.
//

@testable import MirageKitHost
import CoreMedia
import MirageKit
import Testing

#if os(macOS)
@Suite("Host Audio Pipeline Freshness")
struct HostAudioPipelineFreshnessTests {
    @Test("Queue trimming drops oldest buffers to preserve live freshness")
    func queueTrimmingDropsOldestBuffers() {
        var queue = [
            makeBuffer(timestampSeconds: 1),
            makeBuffer(timestampSeconds: 2),
            makeBuffer(timestampSeconds: 3),
        ]
        var duration = 0.300

        let droppedCount = HostAudioPipeline.trimQueuedBuffers(
            &queue,
            queuedDurationSeconds: &duration,
            maxQueuedDurationSeconds: 0.120
        )

        #expect(droppedCount == 2)
        #expect(queue.count == 1)
        #expect(duration <= 0.120)
        #expect(CMTimeGetSeconds(queue[0].presentationTime) == 3)
    }

    @Test("Audio packetizer marks discontinuity on first fragment")
    func audioPacketizerMarksDiscontinuity() async throws {
        let frame = EncodedAudioFrame(
            data: Data(repeating: 0xA5, count: 640),
            codec: .pcm16LE,
            sampleRate: 48_000,
            channelCount: 2,
            samplesPerFrame: 160,
            timestampNs: 1_000
        )
        let packetizer = AudioPacketizer(maxPayloadSize: 256)

        let packets = await packetizer.packetize(frame: frame, streamID: 7, discontinuity: true)

        #expect(packets.count == 3)
        let firstHeader = try #require(AudioPacketHeader.deserialize(from: packets[0]))
        let secondHeader = try #require(AudioPacketHeader.deserialize(from: packets[1]))
        #expect(firstHeader.flags.contains(.discontinuity))
        #expect(!secondHeader.flags.contains(.discontinuity))
    }

    private func makeBuffer(timestampSeconds: Double) -> CapturedAudioBuffer {
        CapturedAudioBuffer(
            data: Data(count: 4_800 * 2 * MemoryLayout<Float>.size),
            sampleRate: 48_000,
            channelCount: 2,
            frameCount: 4_800,
            bytesPerFrame: 2 * MemoryLayout<Float>.size,
            bitsPerChannel: 32,
            isFloat: true,
            isInterleaved: true,
            presentationTime: CMTime(seconds: timestampSeconds, preferredTimescale: 1_000_000_000)
        )
    }
}
#endif
