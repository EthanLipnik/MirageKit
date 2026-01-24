//
//  CursorMonitor.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/3/26.
//

#if os(macOS)
import Foundation
import AppKit

/// Monitors cursor state for active streams and notifies when the cursor type changes.
/// Runs on the host Mac and polls NSCursor.currentSystem at a configurable rate.
actor CursorMonitor {
    /// Polling interval (default 30Hz = ~33ms)
    private let pollingInterval: TimeInterval

    /// Active polling task
    private var pollingTask: Task<Void, Never>?

    /// Last known cursor type per stream (for change detection)
    private var lastCursorTypes: [StreamID: MirageCursorType] = [:]

    /// Last known visibility state per stream
    private var lastVisibility: [StreamID: Bool] = [:]

    /// Callback invoked when cursor changes for a stream
    private var onCursorChange: ((StreamID, MirageCursorType, Bool) -> Void)?

    /// Initialize with a polling rate
    /// - Parameter pollingRate: How many times per second to poll (default 30Hz)
    init(pollingRate: Double = 30.0) {
        self.pollingInterval = 1.0 / pollingRate
    }

    /// Start monitoring cursor state for active streams
    /// - Parameters:
    ///   - windowFrameProvider: Closure that returns current window frames for each active stream (runs on MainActor)
    ///   - onCursorChange: Callback invoked when cursor type changes for a stream
    func start(
        windowFrameProvider: @escaping @MainActor () -> [(StreamID, CGRect)],
        onCursorChange: @escaping @Sendable (StreamID, MirageCursorType, Bool) -> Void
    ) {
        self.onCursorChange = onCursorChange

        // Cancel any existing polling task
        pollingTask?.cancel()

        // Start new polling loop
        pollingTask = Task { [weak self, pollingInterval] in
            while !Task.isCancelled {
                // Get window frames on MainActor since that's where the data lives
                let streams = await MainActor.run { windowFrameProvider() }
                await self?.pollCursor(streams: streams)

                do {
                    try await Task.sleep(nanoseconds: UInt64(pollingInterval * 1_000_000_000))
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
        onCursorChange = nil
    }

    /// Poll current cursor state and check for changes
    private func pollCursor(streams: [(StreamID, CGRect)]) {
        // Get current mouse location in screen coordinates
        // NSEvent.mouseLocation uses bottom-left origin (Cocoa coordinates)
        let mouseLocation = NSEvent.mouseLocation

        for (streamID, windowFrame) in streams {
            // Check if mouse is within this window's frame
            // Note: windowFrame is in screen coordinates with bottom-left origin
            let isInWindow = windowFrame.contains(mouseLocation)

            // ALWAYS detect actual system cursor, regardless of mouse position
            // This ensures cursor changes are sent even when mouse is at window edge
            // or when the cursor changes while interacting from the client
            let cursorType = MirageCursorType(from: NSCursor.currentSystem) ?? .arrow

            // Check for changes from last known state
            let previousType = lastCursorTypes[streamID]
            let previousVisibility = lastVisibility[streamID]

            let typeChanged = cursorType != previousType
            let visibilityChanged = isInWindow != previousVisibility

            if typeChanged || visibilityChanged {
                // Update cached state
                lastCursorTypes[streamID] = cursorType
                lastVisibility[streamID] = isInWindow

                // Notify listener
                onCursorChange?(streamID, cursorType, isInWindow)
            }
        }

        // Clean up stale entries for streams that are no longer active
        let activeStreamIDs = Set(streams.map { $0.0 })
        for streamID in lastCursorTypes.keys where !activeStreamIDs.contains(streamID) {
            lastCursorTypes.removeValue(forKey: streamID)
            lastVisibility.removeValue(forKey: streamID)
        }
    }

    /// Force an immediate cursor update for a specific stream
    func forceUpdate(for streamID: StreamID, windowFrame: CGRect) {
        let mouseLocation = NSEvent.mouseLocation
        let isInWindow = windowFrame.contains(mouseLocation)

        // ALWAYS detect actual cursor type, regardless of mouse position
        let cursorType = MirageCursorType(from: NSCursor.currentSystem) ?? .arrow

        lastCursorTypes[streamID] = cursorType
        lastVisibility[streamID] = isInWindow
        onCursorChange?(streamID, cursorType, isInWindow)
    }
}
#endif
