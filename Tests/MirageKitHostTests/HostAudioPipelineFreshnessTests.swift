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

    @Test("Adaptive audio budget reduces progressively when queue drops")
    func adaptiveAudioBudgetReducesProgressivelyWhenQueueDrops() {
        let configuration = MirageAudioConfiguration(
            enabled: true,
            channelLayout: .stereo,
            quality: .high,
            compressedBitrateBps: 192_000,
            adaptiveCompressionEnabled: true
        )
        var controller = HostAudioCompressionBudgetController(configuration: configuration)

        let reducedBitrate = controller.recordQueueState(
            queuedDurationSeconds: 0.110,
            droppedBuffers: 2,
            maxQueuedDurationSeconds: 0.120
        )

        #expect(reducedBitrate != nil)
        #expect((reducedBitrate ?? 192_000) < 192_000)
        #expect((reducedBitrate ?? 0) >= 64_000)
    }

    @Test("Adaptive audio budget treats configured bitrate as ceiling")
    func adaptiveAudioBudgetTreatsConfiguredBitrateAsCeiling() {
        let configuration = MirageAudioConfiguration(
            enabled: true,
            channelLayout: .stereo,
            quality: .high,
            compressedBitrateBps: 96_000,
            adaptiveCompressionEnabled: true
        )
        var controller = HostAudioCompressionBudgetController(configuration: configuration)

        let recoveredBitrate = controller.recordSuccessfulFrame()

        #expect(controller.currentBitrateBps == 96_000)
        #expect(recoveredBitrate == nil)
    }

    @Test("Adaptive audio budget can recover toward explicit ceiling")
    func adaptiveAudioBudgetCanRecoverTowardExplicitCeiling() {
        let configuration = MirageAudioConfiguration(
            enabled: true,
            channelLayout: .stereo,
            quality: .high,
            compressedBitrateBps: 96_000,
            compressedBitrateCeilingBps: 192_000,
            adaptiveCompressionEnabled: true
        )
        var controller = HostAudioCompressionBudgetController(configuration: configuration)

        let recoveredBitrate = controller.recordSuccessfulFrame()

        #expect((recoveredBitrate ?? 0) > 96_000)
        #expect((recoveredBitrate ?? 0) <= 192_000)
    }

    @Test("Adaptive audio budget applies constrained path startup")
    func adaptiveAudioBudgetAppliesConstrainedPathStartup() {
        let configuration = MirageAudioConfiguration(
            enabled: true,
            channelLayout: .stereo,
            quality: .high,
            compressedBitrateBps: 192_000,
            compressedBitrateCeilingBps: 192_000,
            adaptiveCompressionEnabled: true
        )
        let controller = HostAudioCompressionBudgetController(
            configuration: configuration,
            transportPathKind: .vpn,
            mediaPathProfile: .vpnOrOverlay
        )

        #expect((controller.currentBitrateBps ?? 0) < 192_000)
        #expect((controller.currentBitrateBps ?? 0) >= 64_000)
    }

    @Test("Adaptive audio budget reduces when client reports audio drops")
    func adaptiveAudioBudgetReducesWhenClientReportsAudioDrops() {
        let configuration = MirageAudioConfiguration(
            enabled: true,
            channelLayout: .stereo,
            quality: .high,
            compressedBitrateBps: 192_000,
            adaptiveCompressionEnabled: true
        )
        var controller = HostAudioCompressionBudgetController(configuration: configuration)

        let reducedBitrate = controller.recordReceiverFeedback(
            receiverFeedback(audioDroppedFrameCount: 4, audioGateActive: true)
        )

        #expect(reducedBitrate != nil)
        #expect((reducedBitrate ?? 192_000) < 192_000)
    }

    private func makeBuffer(timestampSeconds: Double) -> CapturedAudioBuffer {
        CapturedAudioBuffer(
            data: Data(count: 4_800 * 2 * MemoryLayout<Float>.size),
            sampleRate: 48_000,
            channelCount: 2,
            frameCount: 4_800,
            bitsPerChannel: 32,
            isFloat: true,
            isInterleaved: true,
            presentationTime: CMTime(seconds: timestampSeconds, preferredTimescale: 1_000_000_000)
        )
    }

    private func receiverFeedback(
        audioDroppedFrameCount: UInt64? = nil,
        audioGateActive: Bool? = nil
    ) -> ReceiverMediaFeedbackMessage {
        ReceiverMediaFeedbackMessage(
            streamID: 1,
            sequence: 1,
            sentAtUptime: 0,
            targetFPS: 60,
            ackRanges: [],
            lostFrameCount: 0,
            discardedPacketCount: 0,
            jitterP95Ms: 0,
            jitterP99Ms: 0,
            queueEstimateFrames: 0,
            reassemblyBacklogFrames: 0,
            reassemblyBacklogKeyframes: 0,
            reassemblyBacklogBytes: 0,
            decodeBacklogFrames: 0,
            presentationBacklogFrames: 0,
            decodedFPS: 60,
            receivedFPS: 60,
            rendererAcceptedFPS: 60,
            rendererPresentedFPS: 60,
            recoveryState: .idle,
            audioDroppedFrameCount: audioDroppedFrameCount,
            audioGateActive: audioGateActive
        )
    }
}
#endif
