//
//  HostStreamRegistry.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/20/26.
//

import Foundation
import MirageKit

#if os(macOS)
/// Thread-safe callbacks keyed by stream identity.
final class HostStreamRegistry: @unchecked Sendable {
    private struct State {
        var typingBurstHandlers: [StreamID: (@Sendable () -> Void)] = [:]
    }

    private let state = Locked(State())

    func registerTypingBurstHandler(
        streamID: StreamID,
        _ handler: @escaping @Sendable () -> Void
    ) {
        state.withLock { $0.typingBurstHandlers[streamID] = handler }
    }

    func unregisterTypingBurstHandler(streamID: StreamID) {
        state.withLock { $0.typingBurstHandlers.removeValue(forKey: streamID) }
    }

    func notifyTypingBurst(streamID: StreamID) {
        let handler = state.read { $0.typingBurstHandlers[streamID] }
        handler?()
    }
}
#endif
