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
    @Test("MirageClientService keeps audio playback controller lazy until first use")
    func clientServiceKeepsAudioPlaybackControllerLazy() {
        let service = MirageClientService(deviceName: "Lazy Audio Test")

        #expect(service.audioPlaybackControllerIfInitialized == nil)

        _ = service.audioPlaybackController

        #expect(service.audioPlaybackControllerIfInitialized != nil)
    }

    @MainActor
    @Test("Audio playback graph initializes only when playback work is requested")
    func audioPlaybackGraphStaysLazyUntilNeeded() {
        let controller = AudioPlaybackController()

        #expect(!controller.hasInitializedPlaybackGraphForTesting())

        _ = controller.preferredChannelCount(for: 2)

        #expect(!controller.hasInitializedPlaybackGraphForTesting())
    }

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
    @Test("Decoded frames that beat audio stream start are buffered and flushed")
    func earlyDecodedFramesAreBufferedUntilAudioStreamStarted() async throws {
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

        try await waitUntil {
            service.pendingDecodedAudioFramesByStreamID[streamID] == nil
        }
        #expect(service.pendingDecodedAudioFramesByStreamID[streamID] == nil)
        service.stopAudioConnection()
    }

    @MainActor
    private func waitUntil(_ predicate: @MainActor () -> Bool) async throws {
        for _ in 0 ..< 20 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private func makeDecodedFrame() -> DecodedPCMFrame {
        let sampleRate = 48_000
        let channelCount = 2
        let frameCount = 4_800
        return DecodedPCMFrame(
            sampleRate: sampleRate,
            channelCount: channelCount,
            frameCount: frameCount,
            timestampNs: 1,
            pcmData: Data(count: frameCount * channelCount * MemoryLayout<Float>.size)
        )
    }
}
