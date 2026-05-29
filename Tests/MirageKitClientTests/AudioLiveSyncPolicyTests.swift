//
//  AudioLiveSyncPolicyTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/3/26.
//
//  Client audio live-sync trimming coverage.
//

@testable import MirageKitClient
import Foundation
import MirageKit
import Testing

@Suite("Audio Live Sync Policy")
struct AudioLiveSyncPolicyTests {
    @Test("Frames far behind submitted video are dropped")
    func dropsFramesFarBehindVideo() {
        let frames = [
            makeFrame(timestampNs: 100_000_000),
            makeFrame(timestampNs: 820_000_000),
            makeFrame(timestampNs: 940_000_000),
        ]

        let filtered = LiveAudioSyncPolicy.filterFramesBehindVideo(
            frames,
            videoTimestampNs: 1_000_000_000,
            maxBehindNs: 180_000_000
        )

        #expect(filtered.droppedCount == 1)
        #expect(filtered.frames.map(\.timestampNs) == [820_000_000, 940_000_000])
    }

    @Test("Policy gates playback and retains only live tail before first video frame")
    func policyGatesBeforeFirstVideoFrame() {
        let frames = [
            makeFrame(timestampNs: 0),
            makeFrame(timestampNs: 100_000_000),
            makeFrame(timestampNs: 200_000_000),
            makeFrame(timestampNs: 300_000_000),
        ]

        let decision = LiveAudioSyncPolicy.decide(
            frames: frames,
            videoState: .waitingForFirstFrame,
            liveTailDurationSeconds: 0.180
        )

        #expect(decision.shouldGatePlayback)
        #expect(decision.reason == "waiting-first-video-frame")
        #expect(decision.droppedCount == 2)
        #expect(decision.frames.map(\.timestampNs) == [200_000_000, 300_000_000])
    }

    @Test("Policy falls back to live audio when video presentation is stale")
    func policyFallsBackToLiveAudioWhenVideoPresentationIsStale() {
        let frames = [
            makeFrame(timestampNs: 1_000_000_000),
            makeFrame(timestampNs: 1_100_000_000),
            makeFrame(timestampNs: 1_200_000_000),
        ]

        let decision = LiveAudioSyncPolicy.decide(
            frames: frames,
            videoState: .staleAfterPresentation,
            liveTailDurationSeconds: 0.150
        )

        #expect(!decision.shouldGatePlayback)
        #expect(decision.reason == "stale-video-presentation")
        #expect(decision.droppedCount == 1)
        #expect(decision.frames.map(\.timestampNs) == [1_100_000_000, 1_200_000_000])
    }

    @Test("Policy resumes near live video without gate")
    func policyResumesAgainstFreshVideo() {
        let frames = [
            makeFrame(timestampNs: 300_000_000),
            makeFrame(timestampNs: 920_000_000),
            makeFrame(timestampNs: 1_060_000_000),
        ]

        let decision = LiveAudioSyncPolicy.decide(
            frames: frames,
            videoState: .fresh(timestampNs: 1_000_000_000),
            maxBehindNs: 180_000_000,
            maxHoldSeconds: 0.080
        )

        #expect(!decision.shouldGatePlayback)
        #expect(decision.droppedCount == 1)
        #expect(decision.frames.map(\.timestampNs) == [920_000_000, 1_060_000_000])
        #expect(decision.runtimeExtraDelaySeconds == 0)
    }

    @Test("Policy holds audio that is ahead of fresh video")
    func policyDelaysAudioAheadOfVideo() {
        let frames = [
            makeFrame(timestampNs: 1_120_000_000),
        ]

        let decision = LiveAudioSyncPolicy.decide(
            frames: frames,
            videoState: .fresh(timestampNs: 1_000_000_000),
            maxHoldSeconds: 0.080
        )

        #expect(!decision.shouldGatePlayback)
        #expect(abs(decision.runtimeExtraDelaySeconds - 0.080) < 0.001)
    }

    @Test("Default live sync policy preserves moderate video lead")
    func defaultPolicyPreservesModerateVideoLead() {
        let frames = [
            makeFrame(timestampNs: 700_000_000),
            makeFrame(timestampNs: 820_000_000),
        ]

        let filtered = LiveAudioSyncPolicy.filterFramesBehindVideo(
            frames,
            videoTimestampNs: 1_000_000_000
        )

        #expect(filtered.droppedCount == 0)
        #expect(filtered.frames.count == frames.count)
    }

    private func makeFrame(timestampNs: UInt64) -> DecodedPCMFrame {
        DecodedPCMFrame(
            sampleRate: 48000,
            channelCount: 2,
            frameCount: 4800,
            timestampNs: timestampNs,
            pcmData: Data(count: 4800 * 2 * MemoryLayout<Float>.size)
        )
    }
}
