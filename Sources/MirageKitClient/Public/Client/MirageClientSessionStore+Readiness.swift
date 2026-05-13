//
//  MirageClientSessionStore+Readiness.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/13/26.
//
//  First-frame readiness and recovery state for client stream sessions.
//

import Foundation
import MirageKit

/// First-frame and recovery-state updates for active or pending client stream sessions.
@MainActor
extension MirageClientSessionStore {
    /// Mark the first decoded frame for a stream.
    public func markFirstFrameDecoded(for streamID: StreamID) {
        let matchingSessions = sessionsMatchingStreamOrMediaID(streamID)
        if !matchingSessions.isEmpty {
            pendingFirstDecodedFrameStreamIDs.remove(streamID)
            for session in matchingSessions {
                pendingFirstDecodedFrameStreamIDs.remove(session.streamID)
                pendingFirstDecodedFrameStreamIDs.remove(session.mediaStreamID)
                if !session.hasDecodedFrame {
                    session.hasDecodedFrame = true
                }
            }
        } else {
            pendingFirstDecodedFrameStreamIDs.insert(streamID)
        }
    }

    /// Reset first-frame readiness for a fresh presentation lifecycle on the same stream.
    public func resetFirstFrameReadiness(for streamID: StreamID) {
        let matchingSessions = sessionsMatchingStreamOrMediaID(streamID)
        pendingFirstDecodedFrameStreamIDs.remove(streamID)
        pendingFirstPresentedFrameStreamIDs.remove(streamID)

        for session in matchingSessions {
            pendingFirstDecodedFrameStreamIDs.remove(session.streamID)
            pendingFirstDecodedFrameStreamIDs.remove(session.mediaStreamID)
            pendingFirstPresentedFrameStreamIDs.remove(session.streamID)
            pendingFirstPresentedFrameStreamIDs.remove(session.mediaStreamID)
            session.hasDecodedFrame = false
            session.hasPresentedFrame = false
        }
    }

    /// Mark the first presented frame for a stream.
    ///
    /// This drives UI state without per-frame SwiftUI updates.
    public func markFirstFramePresented(for streamID: StreamID) {
        let matchingSessions = sessionsMatchingStreamOrMediaID(streamID)
        postResizeAwaitingFirstFrameStreamIDs.remove(streamID)

        if !matchingSessions.isEmpty {
            for session in matchingSessions {
                postResizeAwaitingFirstFrameStreamIDs.remove(session.streamID)
                postResizeAwaitingFirstFrameStreamIDs.remove(session.mediaStreamID)
                pendingFirstDecodedFrameStreamIDs.remove(session.streamID)
                pendingFirstDecodedFrameStreamIDs.remove(session.mediaStreamID)
                pendingFirstPresentedFrameStreamIDs.remove(session.streamID)
                pendingFirstPresentedFrameStreamIDs.remove(session.mediaStreamID)
                if !session.hasDecodedFrame {
                    session.hasDecodedFrame = true
                }
                if !session.hasPresentedFrame {
                    session.hasPresentedFrame = true
                }
            }
        } else {
            pendingFirstDecodedFrameStreamIDs.insert(streamID)
            pendingFirstPresentedFrameStreamIDs.insert(streamID)
        }
    }

    /// Updates client-side recovery status for an active stream.
    ///
    /// If the session has not been created yet, the status is applied once the session appears.
    public func setClientRecoveryStatus(
        for streamID: StreamID,
        status: MirageStreamClientRecoveryStatus
    ) {
        let matchingSessions = sessionsMatchingStreamOrMediaID(streamID)
        if !matchingSessions.isEmpty {
            pendingClientRecoveryStatusByStreamID.removeValue(forKey: streamID)
            for session in matchingSessions where session.clientRecoveryStatus != status {
                session.clientRecoveryStatus = status
            }
        } else {
            pendingClientRecoveryStatusByStreamID[streamID] = status
        }
    }

    /// Marks that a stream should remain in resize-transition UI until a new presented frame arrives.
    public func beginPostResizeTransition(for streamID: StreamID) {
        postResizeAwaitingFirstFrameStreamIDs.insert(streamID)
    }

    /// Clears post-resize transition state for a stream.
    public func clearPostResizeTransition(for streamID: StreamID) {
        postResizeAwaitingFirstFrameStreamIDs.remove(streamID)
    }

    /// Returns whether the stream is awaiting its first post-resize presented frame.
    public func isAwaitingPostResizeFirstFrame(for streamID: StreamID) -> Bool {
        postResizeAwaitingFirstFrameStreamIDs.contains(streamID)
    }

    /// Returns sessions whose logical or media stream ID matches `streamID`.
    func sessionsMatchingStreamOrMediaID(_ streamID: StreamID) -> [MirageStreamSessionState] {
        streamSessions.values.filter {
            $0.streamID == streamID || $0.mediaStreamID == streamID
        }
    }
}
