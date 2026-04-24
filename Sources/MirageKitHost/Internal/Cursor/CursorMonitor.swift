//
//  CursorMonitor.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/3/26.
//

import MirageKit
#if os(macOS)
import AppKit
import Foundation

/// Monitors cursor state for active streams and notifies when the cursor type changes.
/// Runs on the host Mac and polls NSCursor.currentSystem at a configurable rate.
actor CursorMonitor {
    /// Polling interval (default 120Hz = ~8.3ms)
    private let pollingInterval: TimeInterval
    /// Interval for refreshing stream window frames from the provider.
    private let windowFrameRefreshInterval: TimeInterval

    /// Active polling task
    private var pollingTask: Task<Void, Never>?

    /// Cached stream frames sampled from the host service.
    private var cachedStreams: [(StreamID, CGRect)] = []
    private var lastWindowFrameRefreshTime: CFAbsoluteTime = 0

    /// Last known cursor type per stream (for change detection)
    private var lastCursorTypes: [StreamID: MirageCursorType] = [:]

    /// Last known visibility state per stream
    private var lastVisibility: [StreamID: Bool] = [:]
    private var lastCursorPositions: [StreamID: CGPoint] = [:]
    private var lastCursorPositionSentAt: [StreamID: CFAbsoluteTime] = [:]

    /// Expand visibility checks slightly so edge cursors remain visible at window bounds
    private let visibilityPadding: CGFloat = 1.0
    private let positionMovementThreshold: CGFloat = 0.002
    private let positionHeartbeatInterval: CFAbsoluteTime = 0.5

    /// Callback invoked when cursor changes for a stream.
    private var onCursorChange: ((StreamID, MirageCursorType, Bool) async -> Void)?

    /// Callback invoked with cursor position updates for a stream.
    private var onCursorPosition: ((StreamID, CGPoint, Bool) async -> Void)?

    /// Initialize with a polling rate
    /// - Parameters:
    ///   - pollingRate: How many times per second to poll cursor state (default 120Hz).
    ///   - windowFrameRefreshRate: How many times per second to refresh stream frames (default 30Hz).
    init(
        pollingRate: Double = Double(MirageInteractionCadence.targetFPS120),
        windowFrameRefreshRate: Double = 30.0
    ) {
        pollingInterval = Self.normalizedInterval(rate: pollingRate)
        windowFrameRefreshInterval = Self.normalizedInterval(rate: windowFrameRefreshRate)
    }

    /// Start monitoring cursor state for active streams
    /// - Parameters:
    ///   - windowFrameProvider: Closure that returns current window frames for each active stream (runs on MainActor)
    ///   - onCursorChange: Callback invoked when cursor type changes for a stream
    func start(
        windowFrameProvider: @escaping @MainActor () -> [(StreamID, CGRect)],
        onCursorChange: @escaping @Sendable (StreamID, MirageCursorType, Bool) async -> Void,
        onCursorPosition: (@Sendable (StreamID, CGPoint, Bool) async -> Void)? = nil
    ) {
        self.onCursorChange = onCursorChange
        self.onCursorPosition = onCursorPosition

        // Cancel any existing polling task
        pollingTask?.cancel()

        // Start new polling loop
        pollingTask = Task { [weak self, pollingInterval] in
            while !Task.isCancelled {
                guard let self else { break }
                let streams = await self.streamsForTick(
                    windowFrameProvider: windowFrameProvider,
                    now: CFAbsoluteTimeGetCurrent()
                )
                await self.pollCursor(streams: streams)

                do {
                    try await Task.sleep(for: .seconds(pollingInterval))
                } catch {
                    // Task was cancelled
                    break
                }
            }
        }
    }

    /// Stop monitoring
    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
        lastCursorTypes.removeAll()
        lastVisibility.removeAll()
        lastCursorPositions.removeAll()
        lastCursorPositionSentAt.removeAll()
        cachedStreams.removeAll()
        lastWindowFrameRefreshTime = 0
        onCursorChange = nil
        onCursorPosition = nil
    }

    nonisolated static func didCursorStateChange(
        previousType: MirageCursorType?,
        previousVisibility: Bool?,
        cursorType: MirageCursorType,
        isVisible: Bool
    )
    -> Bool {
        cursorType != previousType || isVisible != previousVisibility
    }

    nonisolated static func normalizedInterval(rate: Double) -> TimeInterval {
        let normalizedRate = max(1.0, rate)
        return 1.0 / normalizedRate
    }

    private func streamsForTick(
        windowFrameProvider: @escaping @MainActor () -> [(StreamID, CGRect)],
        now: CFAbsoluteTime
    )
    async -> [(StreamID, CGRect)] {
        let shouldRefreshFrames = cachedStreams.isEmpty ||
            lastWindowFrameRefreshTime == 0 ||
            now - lastWindowFrameRefreshTime >= windowFrameRefreshInterval
        if shouldRefreshFrames {
            cachedStreams = await MainActor.run { windowFrameProvider() }
            lastWindowFrameRefreshTime = now
        }
        return cachedStreams
    }

    /// Poll current cursor state and check for changes
    private func pollCursor(streams: [(StreamID, CGRect)]) async {
        // Get current mouse location in screen coordinates
        // NSEvent.mouseLocation uses bottom-left origin (Cocoa coordinates)
        let mouseLocation = NSEvent.mouseLocation

        for (streamID, windowFrame) in streams {
            // Check if mouse is within this window's frame
            // Note: windowFrame is in screen coordinates with bottom-left origin
            let visibilityFrame = windowFrame.insetBy(dx: -visibilityPadding, dy: -visibilityPadding)
            let isInWindow = visibilityFrame.contains(mouseLocation)
            let normalized = normalizedPosition(mouseLocation, in: windowFrame)

            if let onCursorPosition,
               shouldSendCursorPosition(streamID: streamID, position: normalized, now: CFAbsoluteTimeGetCurrent()) {
                await onCursorPosition(streamID, normalized, isInWindow)
            }

            // ALWAYS detect actual system cursor, regardless of mouse position
            // This ensures cursor changes are sent even when mouse is at window edge
            // or when the cursor changes while interacting from the client
            let cursorType = MirageCursorType(from: NSCursor.currentSystem) ?? .arrow

            // Check for changes from last known state
            let previousType = lastCursorTypes[streamID]
            let previousVisibility = lastVisibility[streamID]

            if Self.didCursorStateChange(
                previousType: previousType,
                previousVisibility: previousVisibility,
                cursorType: cursorType,
                isVisible: isInWindow
            ) {
                // Update cached state
                lastCursorTypes[streamID] = cursorType
                lastVisibility[streamID] = isInWindow

                // Notify listener
                if let onCursorChange {
                    await onCursorChange(streamID, cursorType, isInWindow)
                }
            }
        }

        // Clean up stale entries for streams that are no longer active
        let activeStreamIDs = Set(streams.map(\.0))
        for streamID in lastCursorTypes.keys where !activeStreamIDs.contains(streamID) {
            lastCursorTypes.removeValue(forKey: streamID)
            lastVisibility.removeValue(forKey: streamID)
            lastCursorPositions.removeValue(forKey: streamID)
            lastCursorPositionSentAt.removeValue(forKey: streamID)
        }
    }

    private func shouldSendCursorPosition(streamID: StreamID, position: CGPoint, now: CFAbsoluteTime) -> Bool {
        defer {
            lastCursorPositions[streamID] = position
            lastCursorPositionSentAt[streamID] = now
        }
        guard let previous = lastCursorPositions[streamID],
              let lastSentAt = lastCursorPositionSentAt[streamID] else {
            return true
        }
        let moved = abs(previous.x - position.x) >= positionMovementThreshold ||
            abs(previous.y - position.y) >= positionMovementThreshold
        return moved || now - lastSentAt >= positionHeartbeatInterval
    }

    private func normalizedPosition(_ location: CGPoint, in frame: CGRect) -> CGPoint {
        guard frame.width > 0, frame.height > 0 else { return CGPoint(x: 0.5, y: 0.5) }
        let x = (location.x - frame.minX) / frame.width
        let y = 1.0 - ((location.y - frame.minY) / frame.height)
        return CGPoint(x: x, y: y)
    }

    /// Force an immediate cursor update for a specific stream
    func forceUpdate(for streamID: StreamID, windowFrame: CGRect) async {
        let mouseLocation = NSEvent.mouseLocation
        let visibilityFrame = windowFrame.insetBy(dx: -visibilityPadding, dy: -visibilityPadding)
        let isInWindow = visibilityFrame.contains(mouseLocation)

        // ALWAYS detect actual cursor type, regardless of mouse position
        let cursorType = MirageCursorType(from: NSCursor.currentSystem) ?? .arrow

        lastCursorTypes[streamID] = cursorType
        lastVisibility[streamID] = isInWindow
        if let onCursorChange {
            await onCursorChange(streamID, cursorType, isInWindow)
        }
    }
}
#endif
