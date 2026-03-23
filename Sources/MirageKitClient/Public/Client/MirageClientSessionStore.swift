//
//  MirageClientSessionStore.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/23/26.
//

import Foundation
import Observation
import MirageKit

/// Manages active client stream sessions, readiness state, and presentation tiers.
@Observable
@MainActor
public final class MirageClientSessionStore {
    // MARK: - Stream Sessions

    /// Active stream sessions by session ID.
    private var streamSessions: [StreamSessionID: MirageStreamSessionState] = [:]

    /// Minimum window sizes per session (observable for resize completion detection).
    public var sessionMinSizes: [StreamSessionID: CGSize] = [:]

    /// Monotonic min-size update generation per session.
    /// Increments for every host min-size update, including no-op value repeats.
    public var sessionMinSizeUpdateGenerations: [StreamSessionID: UInt64] = [:]

    /// Current stream presentation tier map.
    public var presentationTierByStreamID: [StreamID: StreamPresentationTier] = [:]

    /// Callback when stream presentation tier changes.
    public var onStreamPresentationTierChanged: ((StreamID, StreamPresentationTier) -> Void)?

    /// Streams that decoded a frame before the session entry existed.
    private var pendingFirstDecodedFrameStreamIDs: Set<StreamID> = []
    /// Streams that presented a frame before the session entry existed.
    private var pendingFirstPresentedFrameStreamIDs: Set<StreamID> = []
    /// Streams currently waiting for the first presented frame after a desktop resize reset.
    public var postResizeAwaitingFirstFrameStreamIDs: Set<StreamID> = []

    // MARK: - Focus State

    /// The currently focused stream session (receives input).
    public var focusedSessionID: StreamSessionID?

    // MARK: - Dependencies

    /// Client service for stream operations.
    public weak var clientService: MirageClientService?

    public init() {}

    // MARK: - Session Management

    /// Get a session by ID.
    /// - Parameter id: Session identifier to look up.
    public func session(for id: StreamSessionID) -> MirageStreamSessionState? {
        streamSessions[id]
    }

    /// Get a session by window ID.
    /// - Parameter windowID: Window identifier to match.
    public func sessionForStream(_ windowID: WindowID) -> MirageStreamSessionState? {
        streamSessions.values.first { $0.window.id == windowID }
    }

    /// Get a session by stream ID.
    /// - Parameter streamID: Stream identifier to match.
    public func sessionByStreamID(_ streamID: StreamID) -> MirageStreamSessionState? {
        streamSessions.values.first { $0.streamID == streamID }
    }

    /// Get all active sessions.
    public var activeSessions: [MirageStreamSessionState] { Array(streamSessions.values) }

    /// Create a new stream session.
    /// - Parameters:
    ///   - streamID: The stream ID assigned by the host.
    ///   - window: The window metadata associated with the stream.
    ///   - hostName: Display name of the host providing the stream.
    ///   - minSize: Optional minimum size in points for the streamed window.
    /// - Returns: The newly created session identifier.
    @discardableResult
    public func createSession(
        streamID: StreamID,
        window: MirageWindow,
        hostName: String,
        minSize: CGSize?
    ) -> StreamSessionID {
        let sessionID = StreamSessionID()

        let state = MirageStreamSessionState(
            id: sessionID,
            streamID: streamID,
            window: window,
            hostName: hostName,
            hasDecodedFrame: pendingFirstDecodedFrameStreamIDs.contains(streamID),
            hasPresentedFrame: pendingFirstPresentedFrameStreamIDs.contains(streamID)
        )
        pendingFirstDecodedFrameStreamIDs.remove(streamID)
        pendingFirstPresentedFrameStreamIDs.remove(streamID)

        if let minSize {
            state.minWidth = CGFloat(minSize.width)
            state.minHeight = CGFloat(minSize.height)
        }

        streamSessions[sessionID] = state
        return sessionID
    }

    /// Remove a stream session and its cached state.
    /// - Parameter sessionID: The session identifier to remove.
    public func removeSession(_ sessionID: StreamSessionID) {
        if focusedSessionID == sessionID { focusedSessionID = nil }
        if let streamID = streamSessions[sessionID]?.streamID {
            postResizeAwaitingFirstFrameStreamIDs.remove(streamID)
            presentationTierByStreamID.removeValue(forKey: streamID)
        }
        streamSessions.removeValue(forKey: sessionID)
        sessionMinSizes.removeValue(forKey: sessionID)
        sessionMinSizeUpdateGenerations.removeValue(forKey: sessionID)
    }

    /// Get stream ID for a session.
    /// - Parameter sessionID: Session identifier to query.
    public func streamID(for sessionID: StreamSessionID) -> StreamID? {
        streamSessions[sessionID]?.streamID
    }

    /// Get window for a session.
    /// - Parameter sessionID: Session identifier to query.
    public func window(for sessionID: StreamSessionID) -> MirageWindow? {
        streamSessions[sessionID]?.window
    }

    /// Update window metadata for an existing session keyed by stream ID.
    /// Used when the host rebinds a slot to a different window while preserving stream ID.
    public func updateSessionWindowMetadata(streamID: StreamID, window: MirageWindow) {
        guard let session = streamSessions.values.first(where: { $0.streamID == streamID }) else { return }
        session.window = window
    }

    // MARK: - Minimum Size Updates

    /// Update minimum size for a stream.
    /// - Parameters:
    ///   - streamID: Stream identifier to update.
    ///   - minSize: Minimum size in points reported by the host.
    public func updateMinimumSize(for streamID: StreamID, minSize: CGSize) {
        guard let sessionEntry = streamSessions.first(where: { $0.value.streamID == streamID }) else { return }

        let session = sessionEntry.value
        session.minWidth = max(1, minSize.width)
        session.minHeight = max(1, minSize.height)

        // Update observable property for views.
        sessionMinSizes[sessionEntry.key] = CGSize(width: session.minWidth, height: session.minHeight)
        sessionMinSizeUpdateGenerations[sessionEntry.key, default: 0] += 1
    }

    // MARK: - Focus Management

    /// Set the focused session for input.
    /// - Parameter sessionID: The session to focus (or nil to clear focus).
    public func setFocusedSession(_ sessionID: StreamSessionID?) {
        guard focusedSessionID != sessionID else { return }
        focusedSessionID = sessionID
    }

    public func presentationTier(for streamID: StreamID) -> StreamPresentationTier {
        presentationTierByStreamID[streamID] ?? .activeLive
    }

    public func applyHostStreamPolicies(_ policies: [MirageStreamPolicy]) {
        let newTiers = Dictionary(uniqueKeysWithValues: policies.map { policy in
            (policy.streamID, policy.tier.presentationTier)
        })
        applyResolvedTiers(newTiers)
    }

    /// Mark the first decoded frame for a stream.
    public func markFirstFrameDecoded(for streamID: StreamID) {
        if let session = streamSessions.values.first(where: { $0.streamID == streamID }) {
            if !session.hasDecodedFrame {
                session.hasDecodedFrame = true
            }
        } else {
            pendingFirstDecodedFrameStreamIDs.insert(streamID)
        }
    }

    /// Mark the first presented frame for a stream.
    /// Used to drive UI state without per-frame SwiftUI updates.
    public func markFirstFramePresented(for streamID: StreamID) {
        postResizeAwaitingFirstFrameStreamIDs.remove(streamID)

        if let session = streamSessions.values.first(where: { $0.streamID == streamID }) {
            if !session.hasDecodedFrame {
                session.hasDecodedFrame = true
            }
            if !session.hasPresentedFrame {
                session.hasPresentedFrame = true
            }
        } else {
            pendingFirstDecodedFrameStreamIDs.insert(streamID)
            pendingFirstPresentedFrameStreamIDs.insert(streamID)
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

    private func applyResolvedTiers(_ tiers: [StreamID: StreamPresentationTier]) {
        let previous = presentationTierByStreamID
        presentationTierByStreamID = tiers

        let changedStreamIDs = Set(previous.keys).union(tiers.keys)
            .filter { previous[$0] != tiers[$0] }
            .sorted()
        for streamID in changedStreamIDs {
            guard let tier = tiers[streamID] else { continue }
            onStreamPresentationTierChanged?(streamID, tier)
        }
    }
}

private extension MirageStreamRuntimeTier {
    var presentationTier: StreamPresentationTier {
        switch self {
        case .activeLive:
            .activeLive
        case .passiveSnapshot:
            .passiveSnapshot
        }
    }
}

/// State for an active stream session.
@Observable
@MainActor
public final class MirageStreamSessionState: Identifiable {
    public let id: StreamSessionID
    public let streamID: StreamID
    public var window: MirageWindow
    public let hostName: String
    public var statistics: MirageStreamStatistics?
    public var hasDecodedFrame: Bool
    public var hasPresentedFrame: Bool
    /// Minimum window size in points (from host).
    public var minWidth: CGFloat = 400
    public var minHeight: CGFloat = 300

    public init(
        id: StreamSessionID,
        streamID: StreamID,
        window: MirageWindow,
        hostName: String,
        statistics: MirageStreamStatistics? = nil,
        hasDecodedFrame: Bool = false,
        hasPresentedFrame: Bool = false,
        minWidth: CGFloat = 400,
        minHeight: CGFloat = 300
    ) {
        self.id = id
        self.streamID = streamID
        self.window = window
        self.hostName = hostName
        self.statistics = statistics
        self.hasDecodedFrame = hasDecodedFrame
        self.hasPresentedFrame = hasPresentedFrame
        self.minWidth = minWidth
        self.minHeight = minHeight
    }
}
