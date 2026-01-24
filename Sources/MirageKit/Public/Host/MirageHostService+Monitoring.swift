//
//  MirageHostService+Monitoring.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/11/26.
//

import Foundation

#if os(macOS)
import AppKit

// MARK: - Cursor and Window Activity Monitoring

extension MirageHostService {
    /// Start monitoring cursor state for active streams
    func startCursorMonitoring() {
        cursorMonitor = CursorMonitor(pollingRate: 30)

        Task {
            await cursorMonitor?.start(
                windowFrameProvider: { [weak self] in
                    guard let self else { return [] }

                    var streams: [(StreamID, CGRect)] = []

                    // Get current window frames for all active app/window streams
                    let appStreams = self.activeStreams.compactMap { session -> (StreamID, CGRect)? in
                        // Get the latest window frame from CGWindowList
                        guard let frame = currentWindowFrame(for: session.window.id) else {
                            return nil
                        }
                        // Convert from CGWindowList coordinates (top-left origin) to Cocoa (bottom-left origin)
                        // NSEvent.mouseLocation uses Cocoa coordinates
                        guard let screen = NSScreen.main else { return nil }
                        let screenHeight = screen.frame.height
                        let cocoaFrame = CGRect(
                            x: frame.origin.x,
                            y: screenHeight - frame.origin.y - frame.height,
                            width: frame.width,
                            height: frame.height
                        )
                        return (session.id, cocoaFrame)
                    }
                    streams.append(contentsOf: appStreams)

                    // Include desktop stream if active
                    // Desktop stream uses NSScreen.main frame since it mirrors the main display
                    if let desktopID = self.desktopStreamID, self.desktopDisplayBounds != nil {
                        if let screen = NSScreen.main {
                            // Use the main screen's frame in Cocoa coordinates (already bottom-left origin)
                            streams.append((desktopID, screen.frame))
                        }
                    }

                    return streams
                },
                onCursorChange: { [weak self] streamID, cursorType, isVisible in
                    Task { @MainActor [weak self] in
                        await self?.sendCursorUpdate(streamID: streamID, cursorType: cursorType, isVisible: isVisible)
                    }
                }
            )
        }
    }

    /// Send cursor update to the client for a specific stream
    func sendCursorUpdate(streamID: StreamID, cursorType: MirageCursorType, isVisible: Bool) async {
        // Find the client context - check both app streams and desktop stream
        let clientContext: ClientContext?
        if let session = activeStreams.first(where: { $0.id == streamID }) {
            clientContext = clientsByConnection.values.first(where: { $0.client.id == session.client.id })
        } else if streamID == desktopStreamID {
            clientContext = desktopStreamClientContext
        } else {
            return
        }

        guard let clientContext else { return }

        let message = CursorUpdateMessage(
            streamID: streamID,
            cursorType: cursorType,
            isVisible: isVisible
        )

        do {
            try await clientContext.send(.cursorUpdate, content: message)
            MirageLogger.host("Cursor update sent: \(cursorType) (visible: \(isVisible))")
        } catch {
            MirageLogger.error(.host, "Failed to send cursor update: \(error)")
        }
    }

    // MARK: - Window Activity Monitoring

    /// Add a window to the activity monitor, starting it if needed
    func addWindowToActivityMonitor(_ windowID: WindowID) async {
        // Create and start monitor if this is the first window
        if windowActivityMonitor == nil {
            let monitor = WindowActivityMonitor()
            windowActivityMonitor = monitor

            await monitor.start(windows: [windowID]) { [weak self] windowID, isActive in
                await self?.handleWindowActivityChange(windowID: windowID, isActive: isActive)
            }
        } else {
            // Monitor already running, just add the window
            await windowActivityMonitor?.addWindow(windowID)
        }
    }

    /// Handle window activity state changes for throttling
    /// - Parameters:
    ///   - windowID: The window whose activity state changed
    ///   - isActive: True if window's app is now frontmost, false otherwise
    func handleWindowActivityChange(windowID: WindowID, isActive: Bool) async {
        // Find the stream for this window
        guard let session = activeStreams.first(where: { $0.window.id == windowID }),
              let context = streamsByID[session.id] else {
            return
        }

        if isActive {
            // Window became active - restore full frame rate and request keyframe
            do {
                let targetFrameRate = await context.getTargetFrameRate()
                try await context.updateFrameRate(targetFrameRate)
                await context.requestKeyframe()
                MirageLogger.host("Window \(windowID) active - restored to \(targetFrameRate) fps with keyframe")
            } catch {
                MirageLogger.error(.host, "Failed to restore frame rate for window \(windowID): \(error)")
            }
        } else {
            // Window became inactive - throttle to 1 fps
            do {
                try await context.updateFrameRate(1)
                MirageLogger.host("Window \(windowID) inactive - throttled to 1 fps")
            } catch {
                MirageLogger.error(.host, "Failed to throttle window \(windowID): \(error)")
            }
        }
    }
}

#endif
