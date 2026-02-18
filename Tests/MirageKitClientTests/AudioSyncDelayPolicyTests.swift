//
//  AudioSyncDelayPolicyTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/18/26.
//
//  Coverage for video-buffer-driven audio sync delay policy.
//

@testable import MirageKitClient
import MirageKit
import Testing

#if os(macOS)
@Suite("Audio Sync Delay Policy")
struct AudioSyncDelayPolicyTests {
    @Test("Runtime policy does not add sync delay")
    func runtimePolicyNoExtraDelay() {
        let snapshot = MirageClientMetricsSnapshot(
            renderBufferDepth: 3,
            decodeHealthy: false,
            hostTargetFrameRate: 60
        )

        let delay = MirageClientService.resolveAudioSyncDelaySeconds(
            snapshot: snapshot,
            fallbackTargetFPS: 60
        )

        #expect(delay == 0)
    }

    @Test("Healthy decode keeps sync delay at zero")
    func healthyDecodeNoExtraDelay() {
        let snapshot = MirageClientMetricsSnapshot(
            renderBufferDepth: 3,
            decodeHealthy: true,
            hostTargetFrameRate: 60
        )

        let delay = MirageClientService.resolveAudioSyncDelaySeconds(
            snapshot: snapshot,
            fallbackTargetFPS: 60
        )

        #expect(delay == 0)
    }

    @MainActor
    @Test("Playback controller applies and removes runtime delay")
    func playbackControllerDelayMutation() {
        let controller = AudioPlaybackController()

        controller.setRuntimeExtraDelay(seconds: 0.04)
        #expect(abs(controller.runtimeExtraDelaySecondsForTesting() - 0.04) < 0.001)

        controller.setRuntimeExtraDelay(seconds: 0)
        #expect(controller.runtimeExtraDelaySecondsForTesting() == 0)
    }
}
#endif
