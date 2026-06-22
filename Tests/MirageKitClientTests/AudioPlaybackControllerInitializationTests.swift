//
//  AudioPlaybackControllerInitializationTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/28/26.
//

@testable import MirageKitClient
@testable import MirageKit
import Foundation
import Testing
import MirageCore
import MirageWire

@Suite("Audio Playback Controller Initialization", .serialized)
struct AudioPlaybackControllerInitializationTests {
    @MainActor
    @Test("Incoming audio format preparation initializes playback ahead of the first frame")
    func incomingFormatPreparationInitializesPlaybackGraph() async {
        let controller = AudioPlaybackController()

        #expect(controller.playbackGraph == nil)
        await controller.prepareForIncomingFormat(sampleRate: 48_000, channelCount: 2)
        #expect(controller.playbackGraph != nil)
        await controller.reset()
    }

    @MainActor
    @Test("Audio stream start prewarms playback graph for announced format")
    func audioStreamStartedPrewarmsPlaybackGraph() async throws {
        let service = MirageClientService(deviceName: "Audio Start Prewarm Test")
        let message = try MirageWire.ControlMessage(
            type: .audioStreamStarted,
            content: MirageWire.AudioStreamStartedMessage(
                streamID: 42,
                codec: .pcm16LE,
                sampleRate: 48_000,
                channelCount: 2
            )
        )

        #expect(service.audioPlaybackControllerIfInitialized == nil)

        service.handleAudioStreamStarted(message)

        let controller = try #require(service.audioPlaybackControllerIfInitialized)
        try await waitUntil(timeout: .seconds(10)) {
            controller.playbackGraph != nil
        }
        #expect(controller.playbackGraph != nil)
        await controller.reset()
        service.stopAudioConnection()
    }

    @MainActor
    @Test("Duplicate audio stream start is idempotent")
    func duplicateAudioStreamStartIsIdempotent() async throws {
        let service = MirageClientService(deviceName: "Duplicate Audio Start Test")
        let message = try ControlMessage(
            type: .audioStreamStarted,
            content: AudioStreamStartedMessage(
                streamID: 42,
                codec: .aacLC,
                sampleRate: 48_000,
                channelCount: 2
            )
        )

        service.handleAudioStreamStarted(message)
        let firstGeneration = service.audioStreamConfigurationGeneration
        service.handleAudioStreamStarted(message)

        #expect(service.audioStreamConfigurationGeneration == firstGeneration)
        #expect(service.activeAudioStreamMessage?.codec == .aacLC)
        service.stopAudioConnection()
    }

    @MainActor
    @Test("Unexpected audio format change on same stream is rejected")
    func unexpectedAudioFormatChangeOnSameStreamIsRejected() async throws {
        let service = MirageClientService(deviceName: "Audio Format Change Test")
        let first = try ControlMessage(
            type: .audioStreamStarted,
            content: AudioStreamStartedMessage(
                streamID: 42,
                codec: .aacLC,
                sampleRate: 48_000,
                channelCount: 2
            )
        )
        let changed = try ControlMessage(
            type: .audioStreamStarted,
            content: AudioStreamStartedMessage(
                streamID: 42,
                codec: .pcm16LE,
                sampleRate: 48_000,
                channelCount: 2
            )
        )

        service.handleAudioStreamStarted(first)
        let firstGeneration = service.audioStreamConfigurationGeneration
        service.handleAudioStreamStarted(changed)

        #expect(service.audioStreamConfigurationGeneration == firstGeneration)
        #expect(service.activeAudioStreamMessage?.codec == .aacLC)
        service.stopAudioConnection()
    }

    @MainActor
    @Test("Decoded frames that beat audio stream start remain buffered until video is ready")
    func earlyDecodedFramesRemainBufferedUntilVideoReady() async throws {
        let service = MirageClientService(deviceName: "Early Audio Buffer Test")
        let streamID: StreamID = 77
        service.audioRegisteredStreamID = streamID

        service.enqueueDecodedAudioFrames([makeDecodedFrame()], for: streamID)

        #expect(service.pendingDecodedAudioFramesByStreamID[streamID]?.count == 1)

        let message = try MirageWire.ControlMessage(
            type: .audioStreamStarted,
            content: MirageWire.AudioStreamStartedMessage(
                streamID: streamID,
                codec: .pcm16LE,
                sampleRate: 48_000,
                channelCount: 2
            )
        )
        service.handleAudioStreamStarted(message)

        try await Task.sleep(for: .milliseconds(100))
        #expect(service.pendingDecodedAudioFramesByStreamID[streamID]?.count == 1)
        service.stopAudioConnection()
    }

    @MainActor
    @Test("Audio session recovery rebuilds the remembered playback format")
    func audioSessionRecoveryRebuildsRememberedPlaybackFormat() async throws {
        let controller = AudioPlaybackController()

        await controller.prepareForIncomingFormat(sampleRate: 48_000, channelCount: 2)
        #expect(controller.isConfigured)
        #expect(controller.configuredSampleRate == 48_000)
        #expect(controller.configuredChannelCount == 2)

        await controller.suspendPlaybackForAudioSessionInterruption(reason: "test-began")
        #expect(!controller.isConfigured)

        await controller.recoverPlaybackAfterAudioSessionReset(reason: "test-ended")

        try await waitUntil(timeout: .seconds(5)) {
            controller.isConfigured
        }
        #expect(controller.configuredSampleRate == 48_000)
        #expect(controller.configuredChannelCount == 2)
        await controller.reset()
    }

    @MainActor
    @Test("Pending startup audio is capped before playback starts")
    func pendingStartupAudioIsCappedBeforePlaybackStarts() async {
        let controller = AudioPlaybackController(startupBufferSeconds: 10, maxQueuedSeconds: 0.25)

        for index in 0 ..< 10 {
            controller.enqueue(makeDecodedFrame(timestampNs: UInt64(index)))
        }

        #expect(controller.pendingDurationSeconds <= 0.25)
        #expect(controller.pendingFrames.count <= 2)
        await controller.reset()
    }

    @MainActor
    @Test("Format changes discard superseded pending startup frames")
    func formatChangesDiscardSupersededPendingStartupFrames() async {
        let controller = AudioPlaybackController(startupBufferSeconds: 10, maxQueuedSeconds: 0.5)

        controller.enqueue(makeDecodedFrame(sampleRate: 48_000, timestampNs: 1))
        controller.enqueue(makeDecodedFrame(sampleRate: 44_100, timestampNs: 2))

        #expect(controller.pendingFrames.count == 1)
        #expect(controller.pendingDurationSeconds < 0.12)
        await controller.reset()
    }

    @MainActor
    @Test("Buffered audio discard clears pending startup frames")
    func bufferedAudioDiscardClearsPendingStartupFrames() async {
        let controller = AudioPlaybackController(startupBufferSeconds: 10, maxQueuedSeconds: 0.5)

        controller.enqueue(makeDecodedFrame(timestampNs: 1))
        controller.enqueue(makeDecodedFrame(timestampNs: 2))
        #expect(controller.pendingFrames.count == 2)

        controller.discardBufferedAudio()

        #expect(controller.pendingFrames.count == 0)
        #expect(controller.pendingDurationSeconds == 0)
        await controller.reset()
    }

    @MainActor
    private func waitUntil(
        timeout: Duration,
        predicate: @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while !Task.isCancelled, ContinuousClock.now < deadline {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private func makeDecodedFrame(
        sampleRate: Int = 48_000,
        channelCount: Int = 2,
        frameCount: Int = 4_800,
        timestampNs: UInt64 = 1
    ) -> DecodedPCMFrame {
        DecodedPCMFrame(
            sampleRate: sampleRate,
            channelCount: channelCount,
            frameCount: frameCount,
            timestampNs: timestampNs,
            pcmData: Data(count: frameCount * channelCount * MemoryLayout<Float>.size)
        )
    }
}
