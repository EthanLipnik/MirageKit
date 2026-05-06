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
        var pointerCoalescingByStreamID: [StreamID: PointerCoalescingState] = [:]
        var customInputHandlers: [StreamID: any MirageCustomStreamInputHandler] = [:]
        var activeInputSessionClientIDs: [UUID: UUID] = [:]
    }

    private static let pointerCoalescingSoftWindow: CFAbsoluteTime = 1.2
    private static let pointerCoalescingHardWindow: CFAbsoluteTime = 2.0
    private static let pointerCoalescingResumeWindow: CFAbsoluteTime = 0.4
    private static let pointerCoalescingMinInterval: CFAbsoluteTime = 1.0 / 60.0

    private let state = Locked(State())

    func registerCustomInputHandler(
        streamID: StreamID,
        _ handler: any MirageCustomStreamInputHandler
    ) {
        state.withLock { $0.customInputHandlers[streamID] = handler }
    }

    func unregisterCustomInputHandler(streamID: StreamID) {
        state.withLock { $0.customInputHandlers.removeValue(forKey: streamID) }
    }

    func customInputHandler(streamID: StreamID) -> (any MirageCustomStreamInputHandler)? {
        state.read { $0.customInputHandlers[streamID] }
    }

    func registerInputSession(_ sessionID: UUID, clientID: UUID) {
        state.withLock { $0.activeInputSessionClientIDs[sessionID] = clientID }
    }

    func unregisterInputSession(_ sessionID: UUID) {
        state.withLock { $0.activeInputSessionClientIDs.removeValue(forKey: sessionID) }
    }

    func unregisterInputSessions(for clientID: UUID) {
        state.withLock { mutableState in
            mutableState.activeInputSessionClientIDs = mutableState.activeInputSessionClientIDs.filter {
                $0.value != clientID
            }
        }
    }

    func isInputSessionActive(_ sessionID: UUID, clientID: UUID) -> Bool {
        state.read { $0.activeInputSessionClientIDs[sessionID] == clientID }
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
