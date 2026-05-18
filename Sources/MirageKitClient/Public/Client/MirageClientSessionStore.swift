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
    @ObservationIgnored
    var streamSessions: [StreamSessionID: MirageStreamSessionState] = [:]
    /// Monotonic token that changes when the session dictionary shape changes.
    public private(set) var sessionRevision: UInt64 = 0

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
    var pendingFirstDecodedFrameStreamIDs: Set<StreamID> = []
    /// Streams that presented a frame before the session entry existed.
    var pendingFirstPresentedFrameStreamIDs: Set<StreamID> = []
    /// Streams currently waiting for the first presented frame after a desktop resize reset.
    public var postResizeAwaitingFirstFrameStreamIDs: Set<StreamID> = []
    /// Recovery states reported before a session entry existed.
    var pendingClientRecoveryStatusByStreamID: [StreamID: MirageStreamClientRecoveryStatus] = [:]

    // MARK: - Focus State

    /// The currently focused stream session (receives input).
    public var focusedSessionID: StreamSessionID?

    // MARK: - Dependencies

    /// Client service for stream operations.
    public weak var clientService: MirageClientService?

    /// Creates an empty client session store.
    public init() {}

    // MARK: - Session Management

    /// Get a session by ID.
    /// - Parameter id: Session identifier to look up.
    public func session(for id: StreamSessionID) -> MirageStreamSessionState? {
        observeStreamSessions()
        return streamSessions[id]
    }

    /// Get a session by window ID.
    /// - Parameter windowID: Window identifier to match.
    public func sessionForStream(_ windowID: WindowID) -> MirageStreamSessionState? {
        observeStreamSessions()
        return streamSessions.values.first { $0.window.id == windowID }
    }

    /// Get a session by stream ID.
    /// - Parameter streamID: Stream identifier to match.
    public func sessionByStreamID(_ streamID: StreamID) -> MirageStreamSessionState? {
        observeStreamSessions()
        return streamSessions.values.first { $0.streamID == streamID }
    }

    /// Get the first session rendering from a physical media stream.
    ///
    /// App-atlas media can back multiple logical sessions. Use this only when
    /// any representative session is enough, such as checking whether media exists.
    /// - Parameter mediaStreamID: Media stream identifier to match.
    public func sessionByMediaStreamID(_ mediaStreamID: StreamID) -> MirageStreamSessionState? {
        observeStreamSessions()
        return streamSessions.values.first { $0.mediaStreamID == mediaStreamID }
    }

    /// Get all active sessions.
    public var activeSessions: [MirageStreamSessionState] {
        observeStreamSessions()
        return Array(streamSessions.values)
    }

    /// Create a new stream session.
    /// - Parameters:
    ///   - streamID: The stream ID assigned by the host.
    ///   - window: The window metadata associated with the stream.
    ///   - hostName: Display name of the host providing the stream.
    ///   - minSize: Optional minimum size in points for the streamed window.
    /// - Returns: The newly created session identifier.
    public func createSession(
        streamID: StreamID,
        mediaStreamID: StreamID,
        window: MirageWindow,
        hostName: String,
        appSessionID: UUID? = nil,
        streamKind: MirageStreamKind = .app,
        logicalTarget: MirageStreamLogicalTarget? = nil,
        atlasRegion: MirageAppAtlasRegion? = nil,
        minSize: CGSize?
    ) -> StreamSessionID {
        let sessionID = StreamSessionID()
        let resolvedLogicalTarget = logicalTarget ?? MirageStreamLogicalTarget(
            streamID: streamID,
            window: window,
            streamKind: streamKind,
            appSessionID: appSessionID
        )
        let initialRecoveryStatus = pendingClientRecoveryStatusByStreamID[streamID] ??
            pendingClientRecoveryStatusByStreamID[mediaStreamID] ??
            streamSessions.values.first(where: { $0.mediaStreamID == mediaStreamID })?.clientRecoveryStatus ??
            .idle
        let initialHasDecodedFrame = pendingFirstDecodedFrameStreamIDs.contains(streamID) ||
            pendingFirstDecodedFrameStreamIDs.contains(mediaStreamID) ||
            streamSessions.values.contains { $0.mediaStreamID == mediaStreamID && $0.hasDecodedFrame }
        let initialHasPresentedFrame = pendingFirstPresentedFrameStreamIDs.contains(streamID) ||
            pendingFirstPresentedFrameStreamIDs.contains(mediaStreamID) ||
            streamSessions.values.contains { $0.mediaStreamID == mediaStreamID && $0.hasPresentedFrame }

        let state = MirageStreamSessionState(
            id: sessionID,
            streamID: streamID,
            mediaStreamID: mediaStreamID,
            window: window,
            hostName: hostName,
            appSessionID: appSessionID,
            streamKind: streamKind,
            logicalTarget: resolvedLogicalTarget,
            atlasRegion: atlasRegion,
            clientRecoveryStatus: initialRecoveryStatus,
            hasDecodedFrame: initialHasDecodedFrame,
            hasPresentedFrame: initialHasPresentedFrame
        )
        pendingFirstDecodedFrameStreamIDs.remove(streamID)
        pendingFirstDecodedFrameStreamIDs.remove(mediaStreamID)
        pendingFirstPresentedFrameStreamIDs.remove(streamID)
        pendingFirstPresentedFrameStreamIDs.remove(mediaStreamID)
        pendingClientRecoveryStatusByStreamID.removeValue(forKey: streamID)
        pendingClientRecoveryStatusByStreamID.removeValue(forKey: mediaStreamID)

        if let minSize {
            state.minWidth = CGFloat(minSize.width)
            state.minHeight = CGFloat(minSize.height)
        }

        streamSessions[sessionID] = state
        markStreamSessionsChanged()
        syncAppAtlasRenderTargets(for: mediaStreamID)
        return sessionID
    }

    /// Registers a new stream session when the caller does not need its generated identifier.
    public func registerSession(
        streamID: StreamID,
        mediaStreamID: StreamID,
        window: MirageWindow,
        hostName: String,
        appSessionID: UUID? = nil,
        streamKind: MirageStreamKind = .app,
        logicalTarget: MirageStreamLogicalTarget? = nil,
        atlasRegion: MirageAppAtlasRegion? = nil,
        minSize: CGSize?
    ) {
        _ = createSession(
            streamID: streamID,
            mediaStreamID: mediaStreamID,
            window: window,
            hostName: hostName,
            appSessionID: appSessionID,
            streamKind: streamKind,
            logicalTarget: logicalTarget,
            atlasRegion: atlasRegion,
            minSize: minSize
        )
    }

    /// Remove a stream session and its cached state.
    /// - Parameter sessionID: The session identifier to remove.
    public func removeSession(_ sessionID: StreamSessionID) {
        if focusedSessionID == sessionID { focusedSessionID = nil }
        var mediaStreamIDToRefresh: StreamID?
        if let session = streamSessions[sessionID] {
            let streamID = session.streamID
            let mediaStreamID = session.mediaStreamID
            mediaStreamIDToRefresh = mediaStreamID
            postResizeAwaitingFirstFrameStreamIDs.remove(streamID)
            presentationTierByStreamID.removeValue(forKey: streamID)
            pendingClientRecoveryStatusByStreamID.removeValue(forKey: streamID)
            let mediaStreamStillRendered = streamSessions.contains { candidateSessionID, session in
                candidateSessionID != sessionID && session.mediaStreamID == mediaStreamID
            }
            if !mediaStreamStillRendered {
                postResizeAwaitingFirstFrameStreamIDs.remove(mediaStreamID)
                presentationTierByStreamID.removeValue(forKey: mediaStreamID)
                pendingClientRecoveryStatusByStreamID.removeValue(forKey: mediaStreamID)
            }
        }
        let removedSession = streamSessions.removeValue(forKey: sessionID)
        if removedSession != nil {
            markStreamSessionsChanged()
        }
        sessionMinSizes.removeValue(forKey: sessionID)
        sessionMinSizeUpdateGenerations.removeValue(forKey: sessionID)
        if let mediaStreamIDToRefresh {
            syncAppAtlasRenderTargets(for: mediaStreamIDToRefresh)
        }
    }

    /// Removes every logical session rendered by a physical media stream.
    func removeSessions(renderingMediaStreamID mediaStreamID: StreamID) {
        let sessionIDs = streamSessions.compactMap { sessionID, session in
            session.mediaStreamID == mediaStreamID || session.streamID == mediaStreamID ? sessionID : nil
        }
        for sessionID in sessionIDs {
            removeSession(sessionID)
        }
    }

    /// Update window metadata for an existing session keyed by stream ID.
    /// Used when the host rebinds a slot to a different window while preserving stream ID.
    public func updateSessionWindowMetadata(
        streamID: StreamID,
        window: MirageWindow,
        atlasRegion: MirageAppAtlasRegion? = nil
    ) {
        guard let session = streamSessions.values.first(where: { $0.streamID == streamID }) else { return }
        session.window = window
        session.atlasRegion = atlasRegion
        markStreamSessionsChanged()
    }

    /// Update only the atlas region for an existing logical stream.
    public func updateSessionAtlasRegion(
        streamID: StreamID,
        atlasRegion: MirageAppAtlasRegion?
    ) {
        guard let session = streamSessions.values.first(where: { $0.streamID == streamID }) else { return }
        session.atlasRegion = atlasRegion
        syncAppAtlasRenderTargets(for: session.mediaStreamID)
    }

    /// Apply a physical app-atlas layout to all logical sessions rendering from that media stream.
    public func updateSessionAtlasRegions(
        mediaStreamID: StreamID,
        layout: MirageAppAtlasLayout
    ) {
        for session in streamSessions.values where session.mediaStreamID == mediaStreamID {
            session.atlasRegion = layout.region(for: session.window.id)
        }
        syncAppAtlasRenderTargets(for: mediaStreamID)
    }

    // MARK: - Minimum Size Updates

    /// Update minimum size for a stream.
    /// - Parameters:
    ///   - streamID: Stream identifier to update.
    ///   - minSize: Minimum size in points reported by the host.
    public func updateMinimumSize(for streamID: StreamID, minSize: CGSize) {
        guard let sessionEntry = streamSessions.first(where: { $0.value.streamID == streamID }) ??
            streamSessions.first(where: { $0.value.mediaStreamID == streamID }) else { return }

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

    /// Returns the current presentation tier for a stream.
    public func presentationTier(for streamID: StreamID) -> StreamPresentationTier {
        presentationTierByStreamID[streamID] ?? .activeLive
    }

    /// Returns the current presentation tier for a logical session.
    public func presentationTier(for session: MirageStreamSessionState) -> StreamPresentationTier {
        presentationTierByStreamID[session.mediaStreamID] ??
            presentationTierByStreamID[session.streamID] ??
            .activeLive
    }

    /// Applies host-provided presentation policies to the local session tier map.
    public func applyHostStreamPolicies(_ policies: [MirageStreamPolicy]) {
        let newTiers = Dictionary(uniqueKeysWithValues: policies.map { policy in
            (policy.streamID, policy.tier.presentationTier)
        })
        let previousTiers = presentationTierByStreamID
        presentationTierByStreamID = newTiers

        let changedStreamIDs = Set(previousTiers.keys).union(newTiers.keys)
            .filter { previousTiers[$0] != newTiers[$0] }
            .sorted()
        for streamID in changedStreamIDs {
            guard let tier = newTiers[streamID] else { continue }
            onStreamPresentationTierChanged?(streamID, tier)
        }
    }

    private func observeStreamSessions() {
        // Reading the revision makes the @ObservationIgnored session dictionary observable.
        _ = sessionRevision
    }

    private func markStreamSessionsChanged() {
        sessionRevision &+= 1
    }

    private func syncAppAtlasRenderTargets(for mediaStreamID: StreamID) {
        let targets = streamSessions.values.compactMap { session -> MirageAppAtlasRenderTarget? in
            guard session.mediaStreamID == mediaStreamID,
                  session.streamID != mediaStreamID,
                  let atlasRegion = session.atlasRegion,
                  atlasRegion.isVisible else {
                return nil
            }
            return MirageAppAtlasRenderTarget(streamID: session.streamID, region: atlasRegion)
        }
        MirageAppAtlasRenderFanout.shared.setTargets(targets, for: mediaStreamID)
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
