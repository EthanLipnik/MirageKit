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
    @Test("Smoothest applies delay from buffered frame depth")
    func smoothestDelayFromBufferDepth() {
        let snapshot = MirageClientMetricsSnapshot(
            renderBufferDepth: 3,
            decodeHealthy: false,
            hostTargetFrameRate: 60
        )

        let delay = MirageClientService.resolveAudioSyncDelaySeconds(
            latencyMode: .smoothest,
            typingBurstActive: false,
            snapshot: snapshot,
            fallbackTargetFPS: 60
        )

        #expect(delay == (2.0 / 60.0))
    }

    @Test("Auto typing burst suppresses additional audio delay")
    func autoTypingBurstSuppressesDelay() {
        let snapshot = MirageClientMetricsSnapshot(
            renderBufferDepth: 3,
            decodeHealthy: false,
            hostTargetFrameRate: 60
        )

        let delay = MirageClientService.resolveAudioSyncDelaySeconds(
            latencyMode: .auto,
            typingBurstActive: true,
            snapshot: snapshot,
            fallbackTargetFPS: 60
        )

        #expect(delay == 0)
    }

    @Test("Healthy decode suppresses additional audio delay")
    func healthyDecodeSuppressesDelay() {
        let snapshot = MirageClientMetricsSnapshot(
            renderBufferDepth: 3,
            decodeHealthy: true,
            hostTargetFrameRate: 60
        )

        let delay = MirageClientService.resolveAudioSyncDelaySeconds(
            latencyMode: .smoothest,
            typingBurstActive: false,
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
