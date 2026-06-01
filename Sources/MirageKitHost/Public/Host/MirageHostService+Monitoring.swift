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
    /// Starts or stops cursor monitoring based on whether any stream can use cursor updates.
    func updateCursorMonitoringForActiveStreams() {
        let shouldMonitor = !activeStreams.isEmpty || desktopStreamID != nil
        if shouldMonitor {
            startCursorMonitoringIfNeeded()
        } else {
            stopCursorMonitoring()
        }
    }

    /// Starts cursor monitoring for active app and desktop streams.
    private func startCursorMonitoringIfNeeded() {
        guard cursorMonitor == nil else { return }

        let monitor = CursorMonitor(
            pollingRate: Double(MirageInteractionCadence.targetFPS120),
            windowFrameRefreshRate: 30
        )
        cursorMonitor = monitor

        cursorMonitoringStartTask?.cancel()
        cursorMonitoringStartTask = Task { [weak self, monitor] in
            await monitor.start(
                windowFrameProvider: { [weak self] in
                    guard let self else { return [] }

                    var streams: [(StreamID, CGRect)] = []

                    // Use the latest known stream frames; avoid querying CGWindowList on every cursor tick.
                    let appStreams = activeStreams.compactMap { session -> (StreamID, CGRect)? in
                        guard let cocoaFrame = cocoaFrame(fromCGWindowFrame: session.window.frame) else { return nil }
                        return (session.id, cocoaFrame)
                    }
                    streams.append(contentsOf: appStreams)

                    if let desktopID = desktopStreamID {
                        if desktopStreamMode == .secondary {
                            if let bounds = resolveDesktopDisplayBoundsForCursorMonitor() {
                                streams.append((desktopID, bounds))
                            }
                        } else {
                            let physicalBounds = desktopPrimaryPhysicalBounds ?? refreshDesktopPrimaryPhysicalBounds()
                            let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
                            streams.append((
                                desktopID,
                                Self.resolvedMirroredDesktopCursorMonitorBounds(
                                    physicalBounds: physicalBounds,
                                    virtualResolution: desktopMirroredVirtualResolution,
                                    primaryHeight: primaryHeight
                                )
                            ))
                        }
                    }

                    return streams
                },
                onCursorChange: { [weak self] streamID, cursorType, isVisible, sampledAt in
                    await MainActor.run { [weak self] in
                        self?.sendCursorUpdate(
                            streamID: streamID,
                            cursorType: cursorType,
                            isVisible: isVisible,
                            sampledAt: sampledAt
                        )
                    }
                },
                onCursorPosition: { [weak self] streamID, position, isVisible in
                    await MainActor.run { [weak self] in
                        guard let self else { return }
                        guard Self.shouldSendCursorPositionUpdate(
                            streamID: streamID,
                            desktopStreamID: self.desktopStreamID,
                            desktopStreamMode: self.desktopStreamMode,
                            desktopCursorPresentation: self.desktopCursorPresentation
                        ) else { return }
                        self.sendCursorPositionUpdate(streamID: streamID, position: position, isVisible: isVisible)
                    }
                }
            )
            await MainActor.run { [weak self] in
                if self?.cursorMonitor === monitor {
                    self?.cursorMonitoringStartTask = nil
                }
            }
        }
    }

    /// Stops cursor monitoring when no stream needs cursor updates.
    func stopCursorMonitoring() {
        cursorMonitoringStartTask?.cancel()
        cursorMonitoringStartTask = nil
        guard let monitor = cursorMonitor else { return }
        cursorMonitor = nil
        Task {
            await monitor.stop()
        }
    }

    /// Sends a cursor shape or visibility update to the client that owns the stream.
    func sendCursorUpdate(
        streamID: StreamID,
        cursorType: MirageCursorType,
        isVisible: Bool,
        sampledAt: CFAbsoluteTime? = nil
    ) {
        let clientContext: ClientContext?
        if let session = activeSessionByStreamID[streamID] {
            clientContext = clientsBySessionID.values.first(where: { $0.client.id == session.client.id })
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

        let sendStart = CFAbsoluteTimeGetCurrent()
        let sent = clientContext.sendBestEffort(.cursorUpdate, content: message)
        MirageCursorLatencyProbe.hostControlSend(
            kind: "shape",
            streamID: streamID,
            sent: sent,
            sampleToSendMilliseconds: sampledAt.map { max(0, (sendStart - $0) * 1_000) },
            sendMilliseconds: MirageCursorLatencyProbe.elapsedMilliseconds(since: sendStart)
        )

        if sent {
            recordCursorControlSendSample(updateSent: true, positionSent: false, updateDropped: false, positionDropped: false)
        } else {
            recordCursorControlSendSample(updateSent: false, positionSent: false, updateDropped: true, positionDropped: false)
        }
    }

    /// Sends a normalized cursor position update for the active desktop stream.
    func sendCursorPositionUpdate(streamID: StreamID, position: CGPoint, isVisible: Bool) {
        guard streamID == desktopStreamID else { return }
        guard let clientContext = desktopStreamClientContext else { return }

        let resolvedPosition = Self.resolvedClientCursorPosition(
            position,
            desktopStreamMode: desktopStreamMode
        )
        let message = CursorPositionUpdateMessage(
            streamID: streamID,
            normalizedX: Float(resolvedPosition.x),
            normalizedY: Float(resolvedPosition.y),
            isVisible: isVisible
        )

        let sendStart = CFAbsoluteTimeGetCurrent()
        let sent = clientContext.sendBestEffort(.cursorPositionUpdate, content: message)
        MirageCursorLatencyProbe.hostControlSend(
            kind: "position",
            streamID: streamID,
            sent: sent,
            sampleToSendMilliseconds: nil,
            sendMilliseconds: MirageCursorLatencyProbe.elapsedMilliseconds(since: sendStart)
        )

        if sent {
            recordCursorControlSendSample(updateSent: false, positionSent: true, updateDropped: false, positionDropped: false)
        } else {
            recordCursorControlSendSample(updateSent: false, positionSent: false, updateDropped: false, positionDropped: true)
        }
    }

    private func cocoaFrame(fromCGWindowFrame frame: CGRect) -> CGRect? {
        guard let primaryScreen = NSScreen.screens.first else { return nil }
        let primaryHeight = primaryScreen.frame.height
        return CGRect(
            x: frame.origin.x,
            y: primaryHeight - frame.origin.y - frame.height,
            width: frame.width,
            height: frame.height
        )
    }

    private func recordCursorControlSendSample(
        updateSent: Bool,
        positionSent: Bool,
        updateDropped: Bool,
        positionDropped: Bool
    ) {
        guard MirageSteadyStateDiagnostics.isEnabled else { return }
        if updateSent { cursorUpdateMessagesSinceLastSample &+= 1 }
        if positionSent { cursorPositionMessagesSinceLastSample &+= 1 }
        if updateDropped { droppedCursorUpdateMessagesSinceLastSample &+= 1 }
        if positionDropped { droppedCursorPositionMessagesSinceLastSample &+= 1 }

        let now = CFAbsoluteTimeGetCurrent()
        if lastCursorControlSampleTime == 0 {
            lastCursorControlSampleTime = now
            return
        }
        guard now - lastCursorControlSampleTime >= cursorControlSampleInterval else { return }

        let updateCount = cursorUpdateMessagesSinceLastSample
        let positionCount = cursorPositionMessagesSinceLastSample
        let droppedUpdateCount = droppedCursorUpdateMessagesSinceLastSample
        let droppedPositionCount = droppedCursorPositionMessagesSinceLastSample
        cursorUpdateMessagesSinceLastSample = 0
        cursorPositionMessagesSinceLastSample = 0
        droppedCursorUpdateMessagesSinceLastSample = 0
        droppedCursorPositionMessagesSinceLastSample = 0
        lastCursorControlSampleTime = now
        guard updateCount > 0 || positionCount > 0 || droppedUpdateCount > 0 || droppedPositionCount > 0 else { return }

        MirageLogger.network(
            """
            Cursor control sample (1s): \
            cursorUpdatesSent=\(updateCount), \
            cursorPositionsSent=\(positionCount), \
            cursorUpdatesDropped=\(droppedUpdateCount), \
            cursorPositionsDropped=\(droppedPositionCount)
            """
        )
    }

    nonisolated static func shouldSendCursorPositionUpdate(
        streamID: StreamID,
        desktopStreamID: StreamID?,
        desktopStreamMode: MirageDesktopStreamMode?,
        desktopCursorPresentation: MirageDesktopCursorPresentation
    ) -> Bool {
        guard streamID == desktopStreamID else { return false }
        return desktopStreamMode == .secondary || desktopCursorPresentation.requiresCursorPositionUpdates
    }

    nonisolated static func resolvedClientCursorPosition(
        _ position: CGPoint,
        desktopStreamMode: MirageDesktopStreamMode?
    )
    -> CGPoint {
        if desktopStreamMode == .secondary { return position }
        return CGPoint(
            x: min(max(position.x, 0), 1),
            y: min(max(position.y, 0), 1)
        )
    }
}

#endif
