//
//  MirageContinuousInputBatcher.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/17/26.
//

import Foundation
import MirageKit

/// Builds bounded compact packets for high-rate continuous input.
final class MirageContinuousInputBatcher: @unchecked Sendable {
    private static let maxPendingNonPencilSamples = 64

    private var pendingBatches: [MirageContinuousInputBatch] = []
    private(set) var droppedNonPencilSamples: UInt64 = 0

    var isEmpty: Bool {
        pendingBatches.isEmpty
    }

    var hasFullPacket: Bool {
        pendingBatches.contains { $0.samples.count >= MirageContinuousInputBatch.maximumSamplesPerPacket }
    }

    func enqueue(_ event: MirageInputEvent, streamID: StreamID) -> Bool {
        guard let batches = MirageContinuousInputBatch.batches(from: event, streamID: streamID) else {
            return false
        }

        for batch in batches where !batch.isEmpty {
            append(batch)
        }
        droppedNonPencilSamples &+= UInt64(trimNonPencilSamplesIfNeeded())
        return true
    }

    func flush() -> [MirageContinuousInputBatch] {
        let batches = pendingBatches
        pendingBatches.removeAll(keepingCapacity: true)
        return batches
    }

    func removeAll() {
        pendingBatches.removeAll(keepingCapacity: false)
    }

    private func append(_ batch: MirageContinuousInputBatch) {
        if let last = pendingBatches.last,
           let merged = last.appending(batch) {
            pendingBatches[pendingBatches.count - 1] = merged
        } else {
            pendingBatches.append(batch)
        }
    }

    private func trimNonPencilSamplesIfNeeded() -> Int {
        var dropped = 0
        while nonPencilSampleCount > Self.maxPendingNonPencilSamples {
            guard removeOldestNonPencilSample() else { break }
            dropped += 1
        }
        return dropped
    }

    private var nonPencilSampleCount: Int {
        pendingBatches.reduce(into: 0) { count, batch in
            guard !batch.isPencilContactBatch else { return }
            count += batch.samples.count
        }
    }

    private func removeOldestNonPencilSample() -> Bool {
        guard let batchIndex = pendingBatches.firstIndex(where: { !$0.isPencilContactBatch }) else {
            return false
        }
        let batch = pendingBatches[batchIndex]
        guard !batch.samples.isEmpty else {
            pendingBatches.remove(at: batchIndex)
            return true
        }

        let remainingSamples = Array(batch.samples.dropFirst())
        if remainingSamples.isEmpty {
            pendingBatches.remove(at: batchIndex)
        } else {
            pendingBatches[batchIndex] = MirageContinuousInputBatch(
                streamID: batch.streamID,
                sequence: batch.sequence,
                kind: batch.kind,
                pointerPhase: batch.pointerPhase,
                scrollPhase: batch.scrollPhase,
                momentumPhase: batch.momentumPhase,
                button: batch.button,
                modifiers: batch.modifiers,
                clickCount: batch.clickCount,
                isButtonPressed: batch.isButtonPressed,
                isPrecise: batch.isPrecise,
                samples: remainingSamples
            )
        }
        return true
    }
}
