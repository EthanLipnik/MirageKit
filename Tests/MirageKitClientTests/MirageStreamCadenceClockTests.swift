//
//  MirageStreamCadenceClockTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/6/26.
//

@testable import MirageKitClient
import CoreMedia
import Testing

#if os(macOS)
@Suite("Stream Cadence Clock")
struct MirageStreamCadenceClockTests {
    @Test("Duplicate and non-monotonic capture timestamps keep cadence PTS monotonic")
    func duplicateAndNonMonotonicCaptureTimestampsKeepCadencePTSMonotonic() {
        for fps in [30, 60, 120] {
            var clock = MirageStreamCadenceClock(targetFPS: fps)
            let first = clock.timing(
                frameNumber: 1,
                remotePresentationTime: CMTime(value: 1_000, timescale: 1_000),
                isKeyframe: true
            )
            let duplicate = clock.timing(
                frameNumber: 2,
                remotePresentationTime: CMTime(value: 1_000, timescale: 1_000),
                isKeyframe: false
            )
            let backward = clock.timing(
                frameNumber: 3,
                remotePresentationTime: CMTime(value: 900, timescale: 1_000),
                isKeyframe: false
            )

            #expect(first.streamPresentationTime == .zero)
            #expect(CMTimeCompare(duplicate.streamPresentationTime, first.streamPresentationTime) > 0)
            #expect(CMTimeCompare(backward.streamPresentationTime, duplicate.streamPresentationTime) > 0)
            #expect(duplicate.duplicateRemoteTimestamp)
            #expect(duplicate.correctedStreamTimestamp)
            #expect(backward.correctedStreamTimestamp)

            let expectedStep = CMTime(value: 1, timescale: CMTimeScale(fps))
            #expect(duplicate.streamPresentationTime == expectedStep)
            #expect(backward.streamPresentationTime == CMTimeMultiply(expectedStep, multiplier: 2))
        }
    }

    @Test("Cadence target changes reset local PTS without carrying old step size")
    func cadenceTargetChangesResetLocalPTSWithoutOldStepSize() {
        var clock = MirageStreamCadenceClock(targetFPS: 30)
        _ = clock.timing(
            frameNumber: 10,
            remotePresentationTime: CMTime(value: 10, timescale: 30),
            isKeyframe: true
        )
        _ = clock.timing(
            frameNumber: 11,
            remotePresentationTime: CMTime(value: 11, timescale: 30),
            isKeyframe: false
        )

        clock.updateTargetFPS(120)
        let reset = clock.timing(
            frameNumber: 12,
            remotePresentationTime: CMTime(value: 12, timescale: 120),
            isKeyframe: false
        )
        let next = clock.timing(
            frameNumber: 13,
            remotePresentationTime: CMTime(value: 13, timescale: 120),
            isKeyframe: false
        )

        #expect(reset.streamPresentationTime == .zero)
        #expect(next.streamPresentationTime == CMTime(value: 1, timescale: 120))
    }
}
#endif
