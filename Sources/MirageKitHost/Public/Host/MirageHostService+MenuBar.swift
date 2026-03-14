//
//  MirageHostService+MenuBar.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/11/26.
//

import Foundation
import Network
import MirageKit

#if os(macOS)

// MARK: - Menu Bar Passthrough

extension MirageHostService {
    /// Handle a menu action request from a client
    func handleMenuActionRequest(
        _ message: ControlMessage,
        from client: MirageConnectedClient,
        connection: NWConnection
    )
    async {
        do {
            let request = try message.decode(MenuActionRequestMessage.self)
            MirageLogger.log(.menuBar, "Client \(client.name) requested menu action: \(request.actionPath)")

            // Find the session and its application
            guard let session = activeSessionByStreamID[request.streamID],
                  let app = session.window.application else {
                let result = MenuActionResultMessage(
                    streamID: request.streamID,
                    success: false,
                    errorMessage: "Stream not found"
                )
                let response = try ControlMessage(type: .menuActionResult, content: result)
                connection.send(content: response.serialize(), completion: .idempotent)
                return
            }

            // Execute the menu action
            let success = await menuBarMonitor.performMenuAction(pid: app.id, actionPath: request.actionPath)

            // Send result
            let result = MenuActionResultMessage(
                streamID: request.streamID,
                success: success,
                errorMessage: success ? nil : "Failed to execute menu action"
            )
            let response = try ControlMessage(type: .menuActionResult, content: result)
            connection.send(content: response.serialize(), completion: .idempotent)
        } catch {
            MirageLogger.error(.menuBar, error: error, message: "Failed to handle menu action request: ")
        }
    }

    /// Start menu bar monitoring for a stream
    func startMenuBarMonitoring(streamID: StreamID, app: MirageApplication, client: MirageConnectedClient) async {
        guard let clientContext = clientsByConnection.values.first(where: { $0.client.id == client.id }) else { return }
        let connection = clientContext.rawConnection

        await menuBarMonitor.startMonitoring(
            streamID: streamID,
            pid: app.id,
            bundleIdentifier: app.bundleIdentifier ?? ""
        ) { [weak self] (menuBar: MirageMenuBar) in
            guard let self else { return }
            Task { @MainActor in
                await self.sendMenuBarUpdate(streamID: streamID, menuBar: menuBar, to: connection)
            }
        }
    }

    /// Send menu bar update to a client
    func sendMenuBarUpdate(streamID: StreamID, menuBar: MirageMenuBar, to connection: NWConnection) async {
        let update = MenuBarUpdateMessage(streamID: streamID, menuBar: menuBar)
        if let message = try? ControlMessage(type: .menuBarUpdate, content: update) { connection.send(content: message.serialize(), completion: .idempotent) }
    }

    /// Stop menu bar monitoring for a stream
    func stopMenuBarMonitoring(streamID: StreamID) async {
        await menuBarMonitor.stopMonitoring(streamID: streamID)
    }

    // MARK: - Desktop Streaming Handlers

    /// Handle a request to start desktop streaming
    func handleStartDesktopStream(
        _ message: ControlMessage,
        from client: MirageConnectedClient,
        connection: NWConnection
    )
    async {
        var pendingLightsOutSetup = false
        do {
            let request = try message.decode(StartDesktopStreamMessage.self)
            MirageLogger
                .host(
                    "Client \(client.name) requested desktop stream: " +
                        "\(request.displayWidth)x\(request.displayHeight) pts, mode=\(request.mode?.displayName ?? "Full Desktop")"
                )

            guard let clientContext = clientsByConnection[ObjectIdentifier(connection)] else {
                MirageLogger.error(.host, "No client context for desktop stream request")
                return
            }

            // Determine target frame rate based on client capability
            let clientMaxRefreshRate = request.maxRefreshRate
            let targetFrameRate = resolvedTargetFrameRate(clientMaxRefreshRate)
            MirageLogger
                .host(
                    "Desktop stream frame rate: \(targetFrameRate)fps (client max=\(clientMaxRefreshRate)Hz)"
                )
            let latencyMode = request.latencyMode ?? .auto
            let performanceMode = request.performanceMode ?? .standard
            MirageLogger.host("Desktop stream latency mode: \(latencyMode.displayName)")
            MirageLogger.host("Desktop stream performance mode: \(performanceMode.displayName)")
            let audioConfiguration = request.audioConfiguration ?? .default

            pendingLightsOutSetup = true
            await beginPendingDesktopStreamLightsOutSetup()
            try await startDesktopStream(
                to: clientContext,
                displayResolution: CGSize(width: request.displayWidth, height: request.displayHeight),
                clientScaleFactor: request.scaleFactor,
                mode: request.mode ?? .mirrored,
                keyFrameInterval: request.keyFrameInterval,
                colorDepth: request.colorDepth,
                captureQueueDepth: request.captureQueueDepth,
                bitrate: request.bitrate,
                latencyMode: latencyMode,
                performanceMode: performanceMode,
                allowRuntimeQualityAdjustment: request.allowRuntimeQualityAdjustment,
                lowLatencyHighResolutionCompressionBoost: request.lowLatencyHighResolutionCompressionBoost ?? true,
                temporaryDegradationMode: request.temporaryDegradationMode ?? .off,
                disableResolutionCap: request.disableResolutionCap ?? false,
                streamScale: request.streamScale,
                audioConfiguration: audioConfiguration,
                dataPort: request.dataPort,
                targetFrameRate: targetFrameRate
            )
            if pendingLightsOutSetup {
                pendingLightsOutSetup = false
                await endPendingDesktopStreamLightsOutSetup()
            }
        } catch {
            if pendingLightsOutSetup {
                pendingLightsOutSetup = false
                await endPendingDesktopStreamLightsOutSetup()
            }
            if Self.isExpectedDesktopStartRejection(error) {
                MirageLogger.host("Desktop stream request rejected: \(error.localizedDescription)")
            } else {
                MirageLogger.error(.host, error: error, message: "Failed to handle desktop stream request: ")
            }
            let errorPayload = Self.desktopStartErrorPayload(for: error)
            if let response = try? ControlMessage(type: .error, content: errorPayload) {
                connection.send(content: response.serialize(), completion: .idempotent)
            }
        }
    }

    /// Handle a request to stop desktop streaming
    func handleStopDesktopStream(_ message: ControlMessage) async {
        do {
            let request = try message.decode(StopDesktopStreamMessage.self)
            MirageLogger.host("Client requested stop desktop stream: \(request.streamID)")

            // Verify the stream ID matches
            guard request.streamID == desktopStreamID else {
                MirageLogger.host("Desktop stream ID mismatch: \(request.streamID) vs \(desktopStreamID ?? 0)")
                return
            }

            await stopDesktopStream(reason: .clientRequested)
        } catch {
            MirageLogger.error(.host, error: error, message: "Failed to handle stop desktop stream: ")
        }
    }

    private nonisolated static func isExpectedDesktopStartRejection(_ error: Error) -> Bool {
        if error is MirageRuntimeConditionError { return true }
        if case let MirageError.protocolError(message) = error {
            return message.contains("Virtual display acquisition failed for desktop stream:")
        }
        return false
    }

    private nonisolated static func desktopStartErrorPayload(for error: Error) -> ErrorMessage {
        if let runtimeCondition = error as? MirageRuntimeConditionError {
            return ErrorMessage(code: .init(runtimeCondition), message: runtimeCondition.message)
        }

        return ErrorMessage(
            code: .virtualDisplayStartFailed,
            message: "Failed to start desktop stream: \(error.localizedDescription)"
        )
    }
}

#endif
