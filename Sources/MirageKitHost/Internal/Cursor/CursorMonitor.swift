//
//  CursorMonitor.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/3/26.
//

import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageKit
import MirageKitClientPresentation
import MirageMedia
import MirageWire
#if os(macOS)
import AppKit
import Foundation

/// Polls host cursor state for active streams and publishes visibility, position, and cursor-shape changes.
actor CursorMonitor {
    private struct CursorSample {
        let mouseLocation: CGPoint
        let cursorType: MirageWire.MirageCursorType
        let source: String
        let sampledAt: CFAbsoluteTime
        let sampleMilliseconds: Double
    }

    /// Expands visibility checks slightly so edge cursors remain visible at window bounds.
    private static let visibilityPadding: CGFloat = 1.0

    /// Minimum normalized movement before sending a cursor position update.
    private static let positionMovementThreshold: CGFloat = 0.002

    /// Maximum interval between cursor position heartbeats when the cursor has not moved.
    private static let positionHeartbeatInterval: CFAbsoluteTime = 0.5

    /// Delay between cursor samples.
    private let pollingInterval: TimeInterval

    /// Interval for refreshing stream window frames from the provider.
    private let windowFrameRefreshInterval: TimeInterval

    /// Task that owns the cursor polling loop.
    private var pollingTask: Task<Void, Never>?

    /// Cached stream frames sampled from the host service.
    private var cachedStreams: [(StreamID, CGRect)] = []
    private var lastWindowFrameRefreshTime: CFAbsoluteTime = 0

    /// Most recent cursor shape sent for each stream.
    private var lastCursorTypes: [StreamID: MirageWire.MirageCursorType] = [:]

    /// Most recent cursor visibility state sent for each stream.
    private var lastVisibility: [StreamID: Bool] = [:]

    /// Most recent normalized cursor position sampled for each stream.
    private var lastCursorPositions: [StreamID: CGPoint] = [:]

    /// Wall-clock time of the most recent cursor position update for each stream.
    private var lastCursorPositionSentAt: [StreamID: CFAbsoluteTime] = [:]

    /// Callback invoked when a stream's cursor shape or visibility changes.
    private var onCursorChange: (@Sendable (StreamID, MirageWire.MirageCursorType, Bool, CFAbsoluteTime) async -> Void)?

    /// Callback invoked with cursor position updates for a stream.
    private var onCursorPosition: ((StreamID, CGPoint, Bool) async -> Void)?

    /// Creates a cursor monitor.
    /// - Parameters:
    ///   - pollingRate: Cursor samples per second.
    ///   - windowFrameRefreshRate: Stream window frame refreshes per second.
    init(
        pollingRate: Double = Double(MirageMedia.MirageInteractionCadence.targetFPS120),
        windowFrameRefreshRate: Double = 30.0
    ) {
        pollingInterval = Self.normalizedInterval(rate: pollingRate)
        windowFrameRefreshInterval = Self.normalizedInterval(rate: windowFrameRefreshRate)
    }

    /// Starts polling cursor state for the stream frames returned by the provider.
    /// - Parameters:
    ///   - windowFrameProvider: Main-actor provider for currently active stream frames.
    ///   - onCursorChange: Callback invoked when cursor shape or visibility changes.
    ///   - onCursorPosition: Optional callback invoked for movement updates and position heartbeats.
    func start(
        windowFrameProvider: @escaping @MainActor () -> [(StreamID, CGRect)],
        onCursorChange: @escaping @Sendable (StreamID, MirageWire.MirageCursorType, Bool, CFAbsoluteTime) async -> Void,
        onCursorPosition: (@Sendable (StreamID, CGPoint, Bool) async -> Void)? = nil
    ) {
        self.onCursorChange = onCursorChange
        self.onCursorPosition = onCursorPosition

        pollingTask?.cancel()

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
                    break
                }
            }
        }
    }

    /// Stops polling and clears all cached cursor state.
    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
        clearTrackedStreamState()
        cachedStreams.removeAll()
        lastWindowFrameRefreshTime = 0
        onCursorChange = nil
        onCursorPosition = nil
    }

    nonisolated static func didCursorStateChange(
        previousType: MirageWire.MirageCursorType?,
        previousVisibility: Bool?,
        cursorType: MirageWire.MirageCursorType,
        isVisible: Bool
    )
    -> Bool {
        cursorType != previousType || isVisible != previousVisibility
    }

    nonisolated static func normalizedInterval(rate: Double) -> TimeInterval {
        let normalizedRate = max(1.0, rate)
        return 1.0 / normalizedRate
    }

    nonisolated static func resolvedCursorType(
        currentSystemCursor: NSCursor?
    )
    -> (cursorType: MirageWire.MirageCursorType, source: String) {
        if let systemType = MirageWire.MirageCursorType(from: currentSystemCursor) {
            return (systemType, "currentSystem")
        }
        return (.arrow, "fallback")
    }

    private func streamsForTick(
        windowFrameProvider: @escaping @MainActor () -> [(StreamID, CGRect)],
        now: CFAbsoluteTime
    )
    async -> [(StreamID, CGRect)] {
        let shouldRefreshFrames = lastWindowFrameRefreshTime == 0 ||
            now - lastWindowFrameRefreshTime >= windowFrameRefreshInterval
        if shouldRefreshFrames {
            cachedStreams = await MainActor.run { windowFrameProvider() }
            lastWindowFrameRefreshTime = now
        }
        return cachedStreams
    }

    /// Samples the current cursor state and publishes changes for active streams.
    private func pollCursor(streams: [(StreamID, CGRect)]) async {
        guard !streams.isEmpty else {
            clearTrackedStreamState()
            return
        }

        let sample = await currentCursorSample()
        let mouseLocation = sample.mouseLocation

        for (streamID, windowFrame) in streams {
            let visibilityFrame = windowFrame.insetBy(dx: -Self.visibilityPadding, dy: -Self.visibilityPadding)
            let isInWindow = visibilityFrame.contains(mouseLocation)
            let normalized = normalizedPosition(mouseLocation, in: windowFrame)

            if let onCursorPosition,
               shouldSendCursorPosition(streamID: streamID, position: normalized, now: CFAbsoluteTimeGetCurrent()) {
                await onCursorPosition(streamID, normalized, isInWindow)
            }

            let cursorType = sample.cursorType

            let previousType = lastCursorTypes[streamID]
            let previousVisibility = lastVisibility[streamID]
            let didChange = Self.didCursorStateChange(
                previousType: previousType,
                previousVisibility: previousVisibility,
                cursorType: cursorType,
                isVisible: isInWindow
            )

            MirageCursorLatencyProbe.hostCursorSample(
                streamID: streamID,
                cursorType: cursorType,
                isVisible: isInWindow,
                didChange: didChange,
                source: sample.source,
                sampleMilliseconds: sample.sampleMilliseconds
            )

            if didChange {
                lastCursorTypes[streamID] = cursorType
                lastVisibility[streamID] = isInWindow

                if let onCursorChange {
                    await onCursorChange(streamID, cursorType, isInWindow, sample.sampledAt)
                }
            }
        }

        let activeStreamIDs = Set(streams.map(\.0))
        for streamID in lastCursorTypes.keys where !activeStreamIDs.contains(streamID) {
            lastCursorTypes.removeValue(forKey: streamID)
            lastVisibility.removeValue(forKey: streamID)
            lastCursorPositions.removeValue(forKey: streamID)
            lastCursorPositionSentAt.removeValue(forKey: streamID)
        }
    }

    private func clearTrackedStreamState() {
        lastCursorTypes.removeAll()
        lastVisibility.removeAll()
        lastCursorPositions.removeAll()
        lastCursorPositionSentAt.removeAll()
    }

    private func currentCursorSample() async -> CursorSample {
        await MainActor.run {
            let sampleStart = CFAbsoluteTimeGetCurrent()
            let mouseLocation = NSEvent.mouseLocation
            let resolvedCursor = Self.resolvedCursorType(
                currentSystemCursor: NSCursor.currentSystem
            )
            return CursorSample(
                mouseLocation: mouseLocation,
                cursorType: resolvedCursor.cursorType,
                source: resolvedCursor.source,
                sampledAt: sampleStart,
                sampleMilliseconds: MirageCursorLatencyProbe.elapsedMilliseconds(since: sampleStart)
            )
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
        let moved = abs(previous.x - position.x) >= Self.positionMovementThreshold ||
            abs(previous.y - position.y) >= Self.positionMovementThreshold
        return moved || now - lastSentAt >= Self.positionHeartbeatInterval
    }

    private func normalizedPosition(_ location: CGPoint, in frame: CGRect) -> CGPoint {
        guard frame.width > 0, frame.height > 0 else { return CGPoint(x: 0.5, y: 0.5) }
        let x = (location.x - frame.minX) / frame.width
        let y = 1.0 - ((location.y - frame.minY) / frame.height)
        return CGPoint(x: x, y: y)
    }
}
#endif
