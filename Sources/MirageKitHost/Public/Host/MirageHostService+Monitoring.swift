//
//  MirageHostService+Monitoring.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/11/26.
//

import Foundation
import MirageKit

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
                    let appStreams = activeStreams.compactMap { session -> (StreamID, CGRect)? in
                        // Get the latest window frame from CGWindowList
                        guard let frame = currentWindowFrame(for: session.window.id) else { return nil }
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
                    if let desktopID = desktopStreamID {
                        if desktopStreamMode == .secondary {
                            if let bounds = resolveDesktopDisplayBoundsForCursorMonitor() {
                                streams.append((desktopID, bounds))
                            }
                        } else if let screen = NSScreen.main {
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
                },
                onCursorPosition: { [weak self] streamID, position, isVisible in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        guard streamID == desktopStreamID, desktopStreamMode == .secondary else { return }
                        await sendCursorPositionUpdate(streamID: streamID, position: position, isVisible: isVisible)
                    }
                }
            )
        }
    }

    /// Send cursor update to the client for a specific stream
    func sendCursorUpdate(streamID: StreamID, cursorType: MirageCursorType, isVisible: Bool) async {
        // Find the client context - check both app streams and desktop stream
        let clientContext: ClientContext?
        if let session = activeSessionByStreamID[streamID] {
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
            MirageLogger.error(.host, error: error, message: "Failed to send cursor update: ")
        }
    }

    /// Send cursor position update to the client for a specific stream
    func sendCursorPositionUpdate(streamID: StreamID, position: CGPoint, isVisible: Bool) async {
        guard streamID == desktopStreamID else { return }
        guard let clientContext = desktopStreamClientContext else { return }

        let clampedX = Float(min(max(position.x, 0), 1))
        let clampedY = Float(min(max(position.y, 0), 1))
        let message = CursorPositionUpdateMessage(
            streamID: streamID,
            normalizedX: clampedX,
            normalizedY: clampedY,
            isVisible: isVisible
        )

        do {
            try await clientContext.send(.cursorPositionUpdate, content: message)
        } catch {
            MirageLogger.error(.host, error: error, message: "Failed to send cursor position update: ")
        }
    }

}

#endif
