//
//  MirageDictationResultBufferTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/2/26.
//

import CoreMedia
import Testing
@testable import MirageKitClient

struct MirageDictationResultBufferTests {
    @Test("Cumulative results emit only the appended suffix")
    func cumulativeResultsEmitDelta() {
        var buffer = MirageDictationResultBuffer()

        let first = buffer.delta(forCumulativeText: "hello")
        let second = buffer.delta(forCumulativeText: "hello world")

        #expect(first == "hello")
        #expect(second == " world")
    }

    @Test("Cumulative results fall back to the full transcript when the prefix changes")
    func cumulativeResultsResetOnTranscriptRewrite() {
        var buffer = MirageDictationResultBuffer()

        _ = buffer.delta(forCumulativeText: "hello world")
        let rewritten = buffer.delta(forCumulativeText: "goodbye world")

        #expect(rewritten == "goodbye world")
    }

    @Test("Buffered final segments drain in spoken order")
    func bufferedFinalSegmentsDrainInRangeOrder() {
        var buffer = MirageDictationResultBuffer()
        buffer.bufferFinalSegment(text: "third", range: makeRange(start: 2, duration: 0.5))
        buffer.bufferFinalSegment(text: "first", range: makeRange(start: 0, duration: 0.5))
        buffer.bufferFinalSegment(text: "second", range: makeRange(start: 1, duration: 0.5))

        let drained = buffer.drainFinalSegments()

        #expect(drained == ["first", "second", "third"])
    }

    @Test("Later final segments replace shorter segments with the same start time")
    func bufferedFinalSegmentsPreferTheMostCompleteRange() {
        var buffer = MirageDictationResultBuffer()
        buffer.bufferFinalSegment(text: "hello", range: makeRange(start: 0, duration: 0.5))
        buffer.bufferFinalSegment(text: "hello there", range: makeRange(start: 0, duration: 1.0))

        let drained = buffer.drainFinalSegments()

        #expect(drained == ["hello there"])
    }

    private func makeRange(start: Double, duration: Double) -> CMTimeRange {
        CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 1_000),
            duration: CMTime(seconds: duration, preferredTimescale: 1_000)
        )
    }
}
