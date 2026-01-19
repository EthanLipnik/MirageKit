//
//  MirageClientSessionStore.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/16/26.
//

import Foundation
import CoreVideo
import Observation

/// Manages active client stream sessions, decoded frames, and cursor state.
@Observable
@MainActor
public final class MirageClientSessionStore {
    // MARK: - Stream Sessions

    /// Active stream sessions by session ID.
    private var streamSessions: [StreamSessionID: MirageStreamSessionState] = [:]

    /// Latest decoded frames for each session.
    public var latestFrames: [StreamSessionID: CVPixelBuffer] = [:]

    /// Content rectangles for each session (for SCK black bar cropping).
    public var contentRects: [StreamSessionID: CGRect] = [:]

    /// Minimum window sizes per session (observable for resize completion detection).
    public var sessionMinSizes: [StreamSessionID: CGSize] = [:]

    // MARK: - Cursor State

    /// Current cursor type per stream.
    public var cursorTypes: [StreamID: MirageCursorType] = [:]

    /// Whether cursor is visible per stream.
    public var cursorVisibility: [StreamID: Bool] = [:]

    // MARK: - Login Display State

    /// Login display stream state (for locked host).
    public var loginDisplayStreamID: StreamID?
    public var loginDisplayResolution: CGSize?
    public var loginDisplayFrame: CVPixelBuffer?
    public var loginDisplayContentRect: CGRect = .zero

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
    public var activeSessions: [MirageStreamSessionState] {
        Array(streamSessions.values)
    }

    /// Get the latest frame for a session.
    /// - Parameter sessionID: Session identifier to query.
    public func latestFrame(for sessionID: StreamSessionID) -> CVPixelBuffer? {
        latestFrames[sessionID]
    }

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

        var state = MirageStreamSessionState(
            id: sessionID,
            streamID: streamID,
            window: window,
            hostName: hostName,
            currentFPS: 0
        )

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
        if focusedSessionID == sessionID {
            focusedSessionID = nil
        }

        streamSessions.removeValue(forKey: sessionID)
        latestFrames.removeValue(forKey: sessionID)
        contentRects.removeValue(forKey: sessionID)
        sessionMinSizes.removeValue(forKey: sessionID)
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

    // MARK: - Frame Handling

    /// Handle a decoded frame from the client service.
    /// - Parameters:
    ///   - streamID: Stream identifier for the decoded frame.
    ///   - pixelBuffer: The decoded pixel buffer.
    ///   - contentRect: Content rectangle for cropping (SCK black bar removal).
    ///   - decodedFPS: Client-side decoded FPS estimate.
    ///   - receivedFPS: Client-side reassembled FPS estimate.
    ///   - droppedFrames: Client-side dropped frame count from reassembly.
    public func handleDecodedFrame(
        streamID: StreamID,
        pixelBuffer: CVPixelBuffer,
        contentRect: CGRect,
        decodedFPS: Double,
        receivedFPS: Double,
        droppedFrames: UInt64
    ) {
        // Check if this is a login display frame.
        if streamID == loginDisplayStreamID {
            loginDisplayFrame = pixelBuffer
            loginDisplayContentRect = contentRect
            return
        }

        // Find the session for this stream.
        if let sessionEntry = streamSessions.first(where: { $0.value.streamID == streamID }) {
            latestFrames[sessionEntry.key] = pixelBuffer
            contentRects[sessionEntry.key] = contentRect
            var session = sessionEntry.value
            session.currentFPS = decodedFPS
            session.receivedFPS = receivedFPS
            session.clientDroppedFrames = droppedFrames
            streamSessions[sessionEntry.key] = session
        }
    }

    public func handleHostStreamMetrics(
        streamID: StreamID,
        encodedFPS: Double,
        idleEncodedFPS: Double,
        droppedFrames: UInt64,
        activeQuality: Float
    ) {
        guard let sessionEntry = streamSessions.first(where: { $0.value.streamID == streamID }) else {
            return
        }

        var session = sessionEntry.value
        session.hostEncodedFPS = encodedFPS
        session.hostIdleFPS = idleEncodedFPS
        session.hostDroppedFrames = droppedFrames
        session.hostActiveQuality = Double(activeQuality)
        streamSessions[sessionEntry.key] = session
    }

    // MARK: - Minimum Size Updates

    /// Update minimum size for a stream.
    /// - Parameters:
    ///   - streamID: Stream identifier to update.
    ///   - minSize: Minimum size in points reported by the host.
    public func updateMinimumSize(for streamID: StreamID, minSize: CGSize) {
        guard let sessionEntry = streamSessions.first(where: { $0.value.streamID == streamID }) else {
            return
        }

        var session = sessionEntry.value
        session.minWidth = max(1, minSize.width)
        session.minHeight = max(1, minSize.height)
        streamSessions[sessionEntry.key] = session

        // Update observable property for views.
        sessionMinSizes[sessionEntry.key] = CGSize(width: session.minWidth, height: session.minHeight)
    }

    // MARK: - Focus Management

    /// Set the focused session for input.
    /// - Parameter sessionID: The session to focus (or nil to clear focus).
    public func setFocusedSession(_ sessionID: StreamSessionID?) {
        guard focusedSessionID != sessionID else { return }
        focusedSessionID = sessionID
    }

    // MARK: - Cursor Updates

    /// Handle cursor update from host.
    /// - Parameters:
    ///   - streamID: Stream identifier for the cursor update.
    ///   - cursorType: The cursor type provided by the host.
    ///   - isVisible: Whether the cursor should be visible.
    public func handleCursorUpdate(streamID: StreamID, cursorType: MirageCursorType, isVisible: Bool) {
        cursorTypes[streamID] = cursorType
        cursorVisibility[streamID] = isVisible
    }

    // MARK: - Login Display

    /// Start login display stream.
    /// - Parameters:
    ///   - streamID: Stream ID for the login display.
    ///   - resolution: Pixel resolution of the login display stream.
    public func startLoginDisplay(streamID: StreamID, resolution: CGSize) {
        loginDisplayStreamID = streamID
        loginDisplayResolution = resolution
        loginDisplayFrame = nil
        loginDisplayContentRect = .zero
    }

    /// Stop login display stream and clear cached frames.
    public func stopLoginDisplay() {
        loginDisplayStreamID = nil
        loginDisplayResolution = nil
        loginDisplayFrame = nil
        loginDisplayContentRect = .zero
    }

    /// Reset all login display state on disconnect.
    public func clearLoginDisplayState() {
        loginDisplayStreamID = nil
        loginDisplayResolution = nil
        loginDisplayFrame = nil
        loginDisplayContentRect = .zero
    }
}

/// State for an active stream session.
public struct MirageStreamSessionState: Identifiable {
    public let id: StreamSessionID
    public let streamID: StreamID
    public let window: MirageWindow
    public let hostName: String
    public var statistics: MirageStreamStatistics?
    public var currentFPS: Double
    public var receivedFPS: Double
    public var hostEncodedFPS: Double
    public var hostIdleFPS: Double
    public var clientDroppedFrames: UInt64
    public var hostDroppedFrames: UInt64
    public var hostActiveQuality: Double
    /// Minimum window size in points (from host).
    public var minWidth: CGFloat = 400
    public var minHeight: CGFloat = 300

    public init(
        id: StreamSessionID,
        streamID: StreamID,
        window: MirageWindow,
        hostName: String,
        statistics: MirageStreamStatistics? = nil,
        currentFPS: Double = 0,
        receivedFPS: Double = 0,
        hostEncodedFPS: Double = 0,
        hostIdleFPS: Double = 0,
        clientDroppedFrames: UInt64 = 0,
        hostDroppedFrames: UInt64 = 0,
        hostActiveQuality: Double = 0,
        minWidth: CGFloat = 400,
        minHeight: CGFloat = 300
    ) {
        self.id = id
        self.streamID = streamID
        self.window = window
        self.hostName = hostName
        self.statistics = statistics
        self.currentFPS = currentFPS
        self.receivedFPS = receivedFPS
        self.hostEncodedFPS = hostEncodedFPS
        self.hostIdleFPS = hostIdleFPS
        self.clientDroppedFrames = clientDroppedFrames
        self.hostDroppedFrames = hostDroppedFrames
        self.hostActiveQuality = hostActiveQuality
        self.minWidth = minWidth
        self.minHeight = minHeight
    }
}
