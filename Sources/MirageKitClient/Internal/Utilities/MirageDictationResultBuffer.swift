//
//  MirageDictationResultBuffer.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/2/26.
//
//  Buffers dictation results so finalized segments can be emitted in spoken order.
//

import CoreMedia
import Foundation

struct MirageDictationResultBuffer {
    private struct BufferedSegment {
        let range: CMTimeRange
        let text: String
    }

    private var lastCommittedCumulativeText = ""
    private var bufferedSegmentsByStart: [RangeStartKey: BufferedSegment] = [:]

    mutating func reset() {
        lastCommittedCumulativeText = ""
        bufferedSegmentsByStart.removeAll(keepingCapacity: true)
    }

    mutating func delta(forCumulativeText fullText: String) -> String? {
        guard !fullText.isEmpty else { return nil }

        if fullText.hasPrefix(lastCommittedCumulativeText) {
            let delta = String(fullText.dropFirst(lastCommittedCumulativeText.count))
            guard !delta.isEmpty else { return nil }
            lastCommittedCumulativeText = fullText
            return delta
        }

        lastCommittedCumulativeText = fullText
        return fullText
    }

    mutating func bufferFinalSegment(text: String, range: CMTimeRange) {
        guard !text.isEmpty else { return }

        let key = RangeStartKey(range.start)
        let newSegment = BufferedSegment(range: range, text: text)

        guard let existingSegment = bufferedSegmentsByStart[key] else {
            bufferedSegmentsByStart[key] = newSegment
            return
        }

        let existingEnd = CMTimeRangeGetEnd(existingSegment.range)
        let newEnd = CMTimeRangeGetEnd(newSegment.range)
        let endComparison = CMTimeCompare(newEnd, existingEnd)
        if endComparison > 0 || (endComparison == 0 && newSegment.text.count >= existingSegment.text.count) {
            bufferedSegmentsByStart[key] = newSegment
        }
    }

    mutating func drainFinalSegments() -> [String] {
        let orderedTexts = bufferedSegmentsByStart.values
            .sorted(by: Self.areSegmentsOrdered)
            .map(\.text)
        bufferedSegmentsByStart.removeAll(keepingCapacity: true)
        lastCommittedCumulativeText = ""
        return orderedTexts
    }

    private static func areSegmentsOrdered(_ lhs: BufferedSegment, _ rhs: BufferedSegment) -> Bool {
        let startComparison = CMTimeCompare(lhs.range.start, rhs.range.start)
        if startComparison != 0 { return startComparison < 0 }

        let endComparison = CMTimeCompare(CMTimeRangeGetEnd(lhs.range), CMTimeRangeGetEnd(rhs.range))
        if endComparison != 0 { return endComparison < 0 }

        return lhs.text < rhs.text
    }
}

private struct RangeStartKey: Hashable {
    let value: Int64
    let timescale: Int32
    let flags: UInt32
    let epoch: Int64

    init(_ time: CMTime) {
        value = time.value
        timescale = time.timescale
        flags = time.flags.rawValue
        epoch = time.epoch
    }
}
