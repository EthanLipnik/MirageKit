//
//  StreamController+MemoryBudgetRecovery.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/12/26.
//
//  Deferred local recovery after memory-budget frame drops.
//

import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageKit
import MirageKitClientPresentation
import MirageMedia
import MirageWire
import Foundation

extension StreamController {
    /// Schedules a bounded local recovery check after memory pressure has time to settle.
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

        discardQueuedFramesForRecovery()
        MirageLogger.client(
            "Memory-budget recovery cleared local decode backlog for stream \(streamID) after deferred stall check"
        )
        lastFreezeRecoveryTime = now
    }
}
