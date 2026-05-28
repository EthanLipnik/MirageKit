//
//  StreamController+MemoryBudgetRecovery.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/12/26.
//
//  Deferred keyframe recovery after memory-budget frame drops.
//

import Foundation
import MirageKit

extension StreamController {
    /// Schedules a bounded keyframe request after memory pressure has time to settle.
    func scheduleMemoryBudgetRecoveryIfNeeded() {
        guard presentationTier == .activeLive,
              hasPresentedFirstFrame,
              memoryBudgetRecoveryTask == nil else { return }

        let baselineSequence = MirageRenderStreamStore.shared.submissionSnapshot(for: streamID).sequence
        memoryBudgetRecoveryTask = Task { [weak self] in
            do {
                try await Task.sleep(for: Self.memoryBudgetRecoveryDelay)
            } catch {
                return
            }
            await self?.requestMemoryBudgetRecoveryIfStillStalled(baselineSequence: baselineSequence)
        }
    }

    private func requestMemoryBudgetRecoveryIfStillStalled(baselineSequence: UInt64) async {
        memoryBudgetRecoveryTask = nil
        guard !isStopping,
              presentationTier == .activeLive,
              hasPresentedFirstFrame,
              reassembler.isAwaitingKeyframe else { return }

        let now = currentTime
        _ = syncPresentationProgressFromFrameStore(now: now)
        let currentSequence = MirageRenderStreamStore.shared.submissionSnapshot(for: streamID).sequence
        guard currentSequence <= baselineSequence else { return }

        if let pendingKeyframeProgress = reassembler.latestPendingKeyframeProgress,
           Self.shouldDeferForPendingKeyframeProgress(
               pendingKeyframeProgress,
               now: now,
               targetFPS: decodeSchedulerTargetFPS
           ) {
            return
        }

        MirageLogger.client(
            "Memory-budget recovery requesting a single keyframe for stream \(streamID) after deferred stall check"
        )
        await enterKeyframeRecoveryIfNeeded(reason: "memory-budget")
        if await requestKeyframeRecovery(reason: .memoryBudget) {
            lastFreezeRecoveryTime = now
        }
    }
}
