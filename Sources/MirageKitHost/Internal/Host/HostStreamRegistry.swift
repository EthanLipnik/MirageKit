//
//  HostStreamRegistry.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/20/26.
//

import Foundation
import MirageKit

#if os(macOS)
/// Thread-safe host stream side table for routing input and temporary pointer throttling.
final class HostStreamRegistry: @unchecked Sendable {
    /// Per-stream pointer throttling state used while capture output is stalled.
    private struct PointerCoalescingState {
        /// Absolute time until pointer move/drag events are allowed to be rate-limited.
        var coalescingDeadline: CFAbsoluteTime = 0
        /// Absolute time when the most recent move/drag event was allowed through.
        var lastForwardedPointerTimestamp: CFAbsoluteTime = 0
    }

    private struct State {
        /// Streams currently eligible for temporary pointer move coalescing.
        var pointerCoalescingByStreamID: [StreamID: PointerCoalescingState] = [:]
        /// Custom-stream input handlers keyed by the stream that owns the handler.
        var customInputHandlers: [StreamID: any MirageCustomStreamInputHandler] = [:]
        /// Active input session IDs mapped to the client that is authorized to use them.
        var activeInputSessionClientIDs: [UUID: UUID] = [:]
    }

    /// Duration used after a soft capture stall where pointer moves are rate-limited.
    private static let pointerCoalescingSoftWindow: CFAbsoluteTime = 1.2
    /// Duration used after a hard capture stall where pointer moves are rate-limited.
    private static let pointerCoalescingHardWindow: CFAbsoluteTime = 2.0
    /// Short drain window after capture resumes so the host does not immediately refill the input queue.
    private static let pointerCoalescingResumeWindow: CFAbsoluteTime = 0.4

    private let state = Locked(State())

    /// Registers the input handler for a custom stream.
    func registerCustomInputHandler(
        streamID: StreamID,
        _ handler: any MirageCustomStreamInputHandler
    ) {
        state.withLock { $0.customInputHandlers[streamID] = handler }
    }

    /// Removes a custom stream input handler when its stream is torn down.
    func unregisterCustomInputHandler(streamID: StreamID) {
        state.withLock { $0.customInputHandlers[streamID] = nil }
    }

    /// Returns the input handler for a custom stream, if one is still registered.
    func customInputHandler(streamID: StreamID) -> (any MirageCustomStreamInputHandler)? {
        state.read { $0.customInputHandlers[streamID] }
    }

    /// Marks an input session as active for one authenticated client.
    func registerInputSession(_ sessionID: UUID, clientID: UUID) {
        state.withLock { $0.activeInputSessionClientIDs[sessionID] = clientID }
    }

    /// Removes an input session after the client stops using it.
    func unregisterInputSession(_ sessionID: UUID) {
        state.withLock { $0.activeInputSessionClientIDs[sessionID] = nil }
    }

    /// Removes every active input session owned by a disconnected client.
    func unregisterInputSessions(for clientID: UUID) {
        state.withLock { mutableState in
            mutableState.activeInputSessionClientIDs = mutableState.activeInputSessionClientIDs.filter {
                $0.value != clientID
            }
        }
    }

    /// Returns whether the session exists and still belongs to the requesting client.
    func isInputSessionActive(_ sessionID: UUID, clientID: UUID) -> Bool {
        state.read { $0.activeInputSessionClientIDs[sessionID] == clientID }
    }

    /// Enables pointer coalescing state for a desktop stream that can report capture stalls.
    func registerPointerCoalescingRoute(streamID: StreamID) {
        state.withLock { mutableState in
            if mutableState.pointerCoalescingByStreamID[streamID] == nil {
                mutableState.pointerCoalescingByStreamID[streamID] = PointerCoalescingState()
            }
        }
    }

    /// Removes pointer coalescing state when the desktop stream is no longer active.
    func unregisterPointerCoalescingRoute(streamID: StreamID) {
        state.withLock { mutableState in
            mutableState.pointerCoalescingByStreamID[streamID] = nil
        }
    }

    /// Extends or clears the pointer coalescing window after a capture stall stage update.
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
