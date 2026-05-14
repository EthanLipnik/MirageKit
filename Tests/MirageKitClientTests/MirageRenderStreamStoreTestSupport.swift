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
        guard let frame = frameForPresentation(for: streamID, after: .zero) else { return nil }
        guard let state = streamStateIfPresent(for: streamID) else { return nil }
        state.lock.lock()
        defer { state.lock.unlock() }

        guard let index = state.pendingFrames.firstIndex(where: { $0.cursor == frame.cursor }) else {
            return nil
        }
        return state.pendingFrames.remove(at: index)
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
