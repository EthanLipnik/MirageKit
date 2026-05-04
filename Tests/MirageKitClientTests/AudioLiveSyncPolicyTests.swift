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

        let filtered = MirageClientService.filterLiveAudioFramesForLiveSync(
            frames,
            videoTimestampNs: 1_000_000_000,
            maxBehindNs: 180_000_000
        )

        #expect(filtered.droppedCount == 1)
        #expect(filtered.frames.map(\.timestampNs) == [820_000_000, 940_000_000])
    }

    @Test("Frames are preserved when video timing is unavailable")
    func preservesFramesWithoutVideoTiming() {
        let frames = [
            makeFrame(timestampNs: 100),
            makeFrame(timestampNs: 200),
        ]

        let filtered = MirageClientService.filterLiveAudioFramesForLiveSync(
            frames,
            videoTimestampNs: nil
        )

        #expect(filtered.droppedCount == 0)
        #expect(filtered.frames.count == frames.count)
    }

    @Test("Default live sync policy preserves moderate video lead")
    func defaultPolicyPreservesModerateVideoLead() {
        let frames = [
            makeFrame(timestampNs: 700_000_000),
            makeFrame(timestampNs: 820_000_000),
        ]

        let filtered = MirageClientService.filterLiveAudioFramesForLiveSync(
            frames,
            videoTimestampNs: 1_000_000_000
        )

        #expect(filtered.droppedCount == 0)
        #expect(filtered.frames.count == frames.count)
    }

    private func makeFrame(timestampNs: UInt64) -> DecodedPCMFrame {
        DecodedPCMFrame(
            sampleRate: 48_000,
            channelCount: 2,
            frameCount: 4_800,
            timestampNs: timestampNs,
            pcmData: Data(count: 4_800 * 2 * MemoryLayout<Float>.size)
        )
    }
}
