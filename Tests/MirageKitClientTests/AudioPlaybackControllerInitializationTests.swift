//
//  AudioPlaybackControllerInitializationTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/28/26.
//

@testable import MirageKitClient
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
}
