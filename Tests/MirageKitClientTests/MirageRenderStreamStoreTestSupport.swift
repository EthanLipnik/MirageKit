//
//  MirageRenderStreamStoreTestSupport.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/12/26.
//

@testable import MirageKitClient
import Foundation

#if os(macOS)
extension MirageRenderStreamStore {
    /// Removes the next pending frame using the same bounded playout queue policy the presenter uses.
    func takePendingFrame(for streamID: StreamID) -> MirageRenderFrame? {
        guard let state = streamStateIfPresent(for: streamID) else { return nil }
        state.lock.lock()
        defer { state.lock.unlock() }

        guard !state.pendingFrames.isEmpty else { return nil }

        let targetDelayFrames = min(max(state.playoutDelayFrames, 0), 2)
        let desiredQueueDepthAfterDequeue = targetDelayFrames
        var droppedLateFrames = 0
        while state.pendingFrames.count > desiredQueueDepthAfterDequeue + 1 {
            state.pendingFrames.removeFirst()
            droppedLateFrames += 1
        }
        if droppedLateFrames > 0 {
            state.lateFrameDropsSinceLastSnapshot &+= UInt64(droppedLateFrames)
            state.coalescedFramesSinceLastSnapshot &+= UInt64(droppedLateFrames)
        }

        return state.pendingFrames.removeFirst()
    }

    /// Returns the oldest pending frame without mutating queue state.
    func peekPendingFrame(for streamID: StreamID) -> MirageRenderFrame? {
        guard let state = streamStateIfPresent(for: streamID) else { return nil }
        state.lock.lock()
        let frame = state.pendingFrames.first
        state.lock.unlock()
        return frame
    }
}
#endif
