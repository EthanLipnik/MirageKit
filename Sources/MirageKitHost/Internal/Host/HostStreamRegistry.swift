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
    private struct PointerCoalescingState {
        var coalescingDeadline: CFAbsoluteTime = 0
        var lastForwardedPointerTimestamp: CFAbsoluteTime = 0
    }

    private struct State {
        var typingBurstHandlers: [StreamID: (@Sendable () -> Void)] = [:]
        var pointerCoalescingByStreamID: [StreamID: PointerCoalescingState] = [:]
    }

    private static let pointerCoalescingSoftWindow: CFAbsoluteTime = 1.2
    private static let pointerCoalescingHardWindow: CFAbsoluteTime = 2.0
    private static let pointerCoalescingResumeWindow: CFAbsoluteTime = 0.4
    private static let pointerCoalescingMinInterval: CFAbsoluteTime = 1.0 / 60.0

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

    func registerPointerCoalescingRoute(streamID: StreamID) {
        state.withLock { mutableState in
            if mutableState.pointerCoalescingByStreamID[streamID] == nil {
                mutableState.pointerCoalescingByStreamID[streamID] = PointerCoalescingState()
            }
        }
    }

    func unregisterPointerCoalescingRoute(streamID: StreamID) {
        state.withLock { mutableState in
            mutableState.pointerCoalescingByStreamID.removeValue(forKey: streamID)
        }
    }

    func noteCaptureStallStage(
        streamID: StreamID,
        stage: CaptureStreamOutput.StallStage,
        now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    ) {
        state.withLock { mutableState in
            guard var coalescingState = mutableState.pointerCoalescingByStreamID[streamID] else { return }
            switch stage {
            case .soft:
                coalescingState.coalescingDeadline = max(
                    coalescingState.coalescingDeadline,
                    now + Self.pointerCoalescingSoftWindow
                )
            case .hard:
                coalescingState.coalescingDeadline = max(
                    coalescingState.coalescingDeadline,
                    now + Self.pointerCoalescingHardWindow
                )
            case .resumed:
                coalescingState.coalescingDeadline = now + Self.pointerCoalescingResumeWindow
            }
            mutableState.pointerCoalescingByStreamID[streamID] = coalescingState
        }
    }

    /// Returns `true` when move/drag pointer input should be dropped for this stream.
    func shouldCoalesceDesktopPointerEvent(
        streamID: StreamID,
        now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent(),
        minInterval: CFAbsoluteTime = 1.0 / 60.0
    ) -> Bool {
        state.withLock { mutableState in
            guard var coalescingState = mutableState.pointerCoalescingByStreamID[streamID] else {
                return false
            }

            if now > coalescingState.coalescingDeadline {
                coalescingState.coalescingDeadline = 0
                coalescingState.lastForwardedPointerTimestamp = 0
                mutableState.pointerCoalescingByStreamID[streamID] = coalescingState
                return false
            }

            if coalescingState.lastForwardedPointerTimestamp > 0,
               now - coalescingState.lastForwardedPointerTimestamp < minInterval {
                mutableState.pointerCoalescingByStreamID[streamID] = coalescingState
                return true
            }

            coalescingState.lastForwardedPointerTimestamp = now
            mutableState.pointerCoalescingByStreamID[streamID] = coalescingState
            return false
        }
    }
}
#endif
