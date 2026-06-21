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
        var governor = HostAudioQualityGovernor(configuration: configuration)

        let reducedProfile = governor.recordQueueState(
            queuedDurationSeconds: 0.110,
            droppedBuffers: 2,
            maxQueuedDurationSeconds: 0.120
        )

        #expect(reducedProfile != nil)
        #expect((reducedProfile?.bitrateBps ?? 192_000) < 192_000)
        #expect((reducedProfile?.bitrateBps ?? 0) >= 64_000)
        #expect(reducedProfile?.codec == .aacLC)
        #expect(reducedProfile?.channelCount == 2)
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
        var governor = HostAudioQualityGovernor(configuration: configuration)

        let recoveredProfile = governor.recordSuccessfulFrame()

        #expect(governor.profile?.bitrateBps == 96_000)
        #expect(recoveredProfile == nil)
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
        var governor = HostAudioQualityGovernor(configuration: configuration)

        let recoveredProfile = governor.recordSuccessfulFrame()

        #expect((recoveredProfile?.bitrateBps ?? 0) > 96_000)
        #expect((recoveredProfile?.bitrateBps ?? 0) <= 192_000)
        #expect(recoveredProfile?.codec == .aacLC)
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
        let governor = HostAudioQualityGovernor(
            configuration: configuration,
            transportPathKind: .vpn,
            mediaPathProfile: .vpnOrOverlay
        )

        #expect((governor.profile?.bitrateBps ?? 0) < 192_000)
        #expect((governor.profile?.bitrateBps ?? 0) >= 64_000)
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
        var governor = HostAudioQualityGovernor(configuration: configuration)

        let reducedProfile = governor.recordReceiverFeedback(
            receiverFeedback(audioDroppedFrameCount: 4, audioGateActive: true)
        )

        #expect(reducedProfile != nil)
        #expect((reducedProfile?.bitrateBps ?? 192_000) < 192_000)
    }

    @Test("Silence gate suppresses sustained silent audio and resumes on signal")
    func silenceGateSuppressesSustainedSilentAudioAndResumesOnSignal() {
        let configuration = MirageAudioConfiguration(
            enabled: true,
            channelLayout: .stereo,
            quality: .high,
            compressedBitrateBps: 128_000,
            adaptiveCompressionEnabled: true
        )
        var governor = HostAudioQualityGovernor(configuration: configuration)

        for _ in 0 ..< 5 {
            _ = governor.activityDecision(for: makeBuffer(data: Data(count: 4_800 * 2 * MemoryLayout<Float32>.size)))
        }

        let gated = governor.activityDecision(for: makeBuffer(data: Data(count: 4_800 * 2 * MemoryLayout<Float32>.size)))
        #expect(gated == .gated(peak: 0))

        var signal = Data()
        for _ in 0 ..< 4_800 * 2 {
            var sample = Float32(0.20)
            withUnsafeBytes(of: &sample) { signal.append(contentsOf: $0) }
        }
        let resumed = governor.activityDecision(for: makeBuffer(data: signal))
        switch resumed {
        case .send:
            break
        case .gated:
            Issue.record("Expected signaled audio to resume sending")
        }
    }

    @Test("Captured audio peak estimator distinguishes silence from signal")
    func capturedAudioPeakEstimatorDistinguishesSilenceFromSignal() {
        var signal = Data()
        for index in 0 ..< 64 {
            var sample = Float32(index.isMultiple(of: 2) ? 0.25 : -0.5)
            withUnsafeBytes(of: &sample) { signal.append(contentsOf: $0) }
        }
        let silentBuffer = makeBuffer(data: Data(count: 64 * MemoryLayout<Float32>.size))
        let signalBuffer = makeBuffer(data: signal)

        #expect(silentBuffer.estimatedPeakAmplitude() == 0)
        #expect(signalBuffer.estimatedPeakAmplitude() >= 0.49)
    }

    private func makeBuffer(timestampSeconds: Double) -> CapturedAudioBuffer {
        makeBuffer(
            data: Data(count: 4_800 * 2 * MemoryLayout<Float>.size),
            timestampSeconds: timestampSeconds
        )
    }

    private func makeBuffer(
        data: Data,
        timestampSeconds: Double = 1
    ) -> CapturedAudioBuffer {
        CapturedAudioBuffer(
            data: data,
            sampleRate: 48_000,
            channelCount: 2,
            frameCount: max(1, data.count / (2 * MemoryLayout<Float>.size)),
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
