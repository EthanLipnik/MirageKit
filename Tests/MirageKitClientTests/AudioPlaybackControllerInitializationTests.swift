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

@Suite("Audio Playback Controller Initialization")
struct AudioPlaybackControllerInitializationTests {

    @MainActor
    @Test("Incoming audio format preparation initializes playback ahead of the first frame")
    func incomingFormatPreparationInitializesPlaybackGraph() async {
        let controller = AudioPlaybackController()

        #expect(!controller.hasInitializedPlaybackGraphForTesting())
        #expect(await controller.prepareForIncomingFormat(sampleRate: 48_000, channelCount: 2))
        #expect(controller.hasInitializedPlaybackGraphForTesting())
    }

    @MainActor
    @Test("Audio stream start prewarms playback graph for announced format")
    func audioStreamStartedPrewarmsPlaybackGraph() async throws {
        let service = MirageClientService(deviceName: "Audio Start Prewarm Test")
        let message = try ControlMessage(
            type: .audioStreamStarted,
            content: AudioStreamStartedMessage(
                streamID: 42,
                codec: .pcm16LE,
                sampleRate: 48_000,
                channelCount: 2
            )
        )

        #expect(service.audioPlaybackControllerIfInitialized == nil)

        service.handleAudioStreamStarted(message)

        let controller = try #require(service.audioPlaybackControllerIfInitialized)
        try await waitUntil {
            controller.hasInitializedPlaybackGraphForTesting()
        }
        #expect(controller.hasInitializedPlaybackGraphForTesting())
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

        let message = try ControlMessage(
            type: .audioStreamStarted,
            content: AudioStreamStartedMessage(
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
    @Test("Pending startup audio is capped before playback starts")
    func pendingStartupAudioIsCappedBeforePlaybackStarts() {
        let controller = AudioPlaybackController(startupBufferSeconds: 10, maxQueuedSeconds: 0.25)

        for index in 0 ..< 10 {
            controller.enqueue(makeDecodedFrame(timestampNs: UInt64(index)))
        }

        #expect(controller.pendingDurationSecondsForTesting() <= 0.25)
        #expect(controller.pendingFrameCountForTesting() <= 2)
    }

    @MainActor
    @Test("Format changes discard superseded pending startup frames")
    func formatChangesDiscardSupersededPendingStartupFrames() {
        let controller = AudioPlaybackController(startupBufferSeconds: 10, maxQueuedSeconds: 0.5)

        controller.enqueue(makeDecodedFrame(sampleRate: 48_000, timestampNs: 1))
        controller.enqueue(makeDecodedFrame(sampleRate: 44_100, timestampNs: 2))

        #expect(controller.pendingFrameCountForTesting() == 1)
        #expect(controller.pendingDurationSecondsForTesting() < 0.12)
    }

    @MainActor
    @Test("Buffered audio discard clears pending startup frames")
    func bufferedAudioDiscardClearsPendingStartupFrames() {
        let controller = AudioPlaybackController(startupBufferSeconds: 10, maxQueuedSeconds: 0.5)

        controller.enqueue(makeDecodedFrame(timestampNs: 1))
        controller.enqueue(makeDecodedFrame(timestampNs: 2))
        #expect(controller.pendingFrameCountForTesting() == 2)

        controller.discardBufferedAudio()

        #expect(controller.pendingFrameCountForTesting() == 0)
        #expect(controller.pendingDurationSecondsForTesting() == 0)
    }

    @MainActor
    @Test("Playback recovery tears down initialized graph")
    func playbackRecoveryTearsDownInitializedGraph() async {
        let controller = AudioPlaybackController()

        #expect(await controller.prepareForIncomingFormat(sampleRate: 48_000, channelCount: 2))
        #expect(controller.hasInitializedPlaybackGraphForTesting())

        await controller.recoverPlaybackGraphForTesting()

        #expect(!controller.hasInitializedPlaybackGraphForTesting())
    }

    @MainActor
    private func waitUntil(_ predicate: @MainActor () -> Bool) async throws {
        for _ in 0 ..< 20 {
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
        return DecodedPCMFrame(
            sampleRate: sampleRate,
            channelCount: channelCount,
            frameCount: frameCount,
            timestampNs: timestampNs,
            pcmData: Data(count: frameCount * channelCount * MemoryLayout<Float>.size)
        )
    }
}
