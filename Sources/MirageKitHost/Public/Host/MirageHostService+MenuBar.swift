//
//  MirageHostService+MenuBar.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/11/26.
//

import CoreGraphics
import Foundation
import MirageKit

#if os(macOS)

// MARK: - Menu Bar Passthrough

extension MirageHostService {
    /// Handle a menu action request from a client
    func handleMenuActionRequest(
        _ message: ControlMessage,
        from clientContext: ClientContext
    )
    async {
        do {
            let request = try message.decode(MenuActionRequestMessage.self)
            MirageLogger.log(.menuBar, "Client \(clientContext.client.name) requested menu action: \(request.actionPath)")

            // Find the session and its application
            guard let session = activeSessionByStreamID[request.streamID],
                  let app = session.window.application else {
                let result = MenuActionResultMessage(
                    streamID: request.streamID,
                    success: false,
                    errorMessage: "Stream not found"
                )
                let response = try ControlMessage(type: .menuActionResult, content: result)
                clientContext.sendBestEffort(response)
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
            clientContext.sendBestEffort(response)
        } catch {
            MirageLogger.error(.menuBar, error: error, message: "Failed to handle menu action request: ")
        }
    }

    /// Start menu bar monitoring for a stream
    func startMenuBarMonitoring(streamID: StreamID, app: MirageApplication, client: MirageConnectedClient) async {
        guard let clientContext = clientsBySessionID.values.first(where: { $0.client.id == client.id }) else { return }

        await menuBarMonitor.startMonitoring(
            streamID: streamID,
            pid: app.id,
            bundleIdentifier: app.bundleIdentifier ?? ""
        ) { [weak self] (menuBar: MirageMenuBar) in
            guard let self else { return }
            Task { @MainActor in
                await self.sendMenuBarUpdate(streamID: streamID, menuBar: menuBar, to: clientContext)
            }
        }
    }

    /// Send menu bar update to a client
    func sendMenuBarUpdate(streamID: StreamID, menuBar: MirageMenuBar, to clientContext: ClientContext) async {
        let update = MenuBarUpdateMessage(streamID: streamID, menuBar: menuBar)
        if let message = try? ControlMessage(type: .menuBarUpdate, content: update) { clientContext.sendBestEffort(message) }
    }

    /// Stop menu bar monitoring for a stream
    func stopMenuBarMonitoring(streamID: StreamID) async {
        await menuBarMonitor.stopMonitoring(streamID: streamID)
    }

    // MARK: - Desktop Streaming Handlers

    /// Handle a request to start desktop streaming
    func handleStartDesktopStream(
        _ message: ControlMessage,
        from clientContext: ClientContext
    )
    async {
        var pendingLightsOutSetup = false
        do {
            let request = try message.decode(StartDesktopStreamMessage.self)
            await cancelQualityTest(
                for: clientContext.client.id,
                reason: "desktop stream startup"
            )
            MirageLogger
                .host(
                    "Client \(clientContext.client.name) requested desktop stream: " +
                        "\(request.displayWidth)x\(request.displayHeight) pts, mode=\(request.mode?.displayName ?? "Full Desktop")"
                )
            let enteredBitrateText = request.enteredBitrate.map(Self.formatBitrateForLogging) ?? "n/a"
            let requestedBitrateText = request.bitrate.map(Self.formatBitrateForLogging) ?? "auto"
            let ceilingText = request.bitrateAdaptationCeiling.map(Self.formatBitrateForLogging) ?? "none"
            MirageLogger.host(
                "Desktop bitrate contract received: entered=\(enteredBitrateText) requested=\(requestedBitrateText) ceiling=\(ceilingText)"
            )

            // Determine target frame rate based on client capability
            let clientMaxRefreshRate = request.maxRefreshRate
            let targetFrameRate = resolvedTargetFrameRate(clientMaxRefreshRate)
            MirageLogger
                .host(
                    "Desktop stream frame rate: \(targetFrameRate)fps (client max=\(clientMaxRefreshRate)Hz)"
                )
            let latencyMode = request.latencyMode ?? .lowestLatency
            let performanceMode = request.performanceMode ?? .standard
            let pathKind = clientContext.pathSnapshot.map { MirageNetworkPathClassifier.classify($0).kind }
            let acceptedMediaMaxPacketSize = mirageNegotiatedMediaMaxPacketSize(
                requested: request.mediaMaxPacketSize,
                pathKind: pathKind
            )
            MirageLogger.host("Desktop stream latency mode: \(latencyMode.displayName)")
            MirageLogger.host("Desktop stream performance mode: \(performanceMode.displayName)")
            let audioConfiguration = request.audioConfiguration ?? .default

            let displayResolution: CGSize = if request.useHostResolution == true {
                Self.hostMainDisplayLogicalResolution()
                    ?? CGSize(width: request.displayWidth, height: request.displayHeight)
            } else {
                CGSize(width: request.displayWidth, height: request.displayHeight)
            }
            if request.useHostResolution == true {
                MirageLogger.host(
                    "Using host display resolution: \(Int(displayResolution.width))x\(Int(displayResolution.height)) pts"
                )
            }

            desktopStreamMode = request.mode ?? .mirrored
            desktopUsesHostResolution = request.useHostResolution == true
            desktopCursorPresentation = request.cursorPresentation ?? .clientCursor
            pendingLightsOutSetup = true
            await beginPendingDesktopStreamLightsOutSetup()
            try await startDesktopStream(
                to: clientContext,
                displayResolution: displayResolution,
                clientScaleFactor: request.scaleFactor,
                mode: request.mode ?? .mirrored,
                cursorPresentation: request.cursorPresentation ?? .clientCursor,
                keyFrameInterval: request.keyFrameInterval,
                colorDepth: request.colorDepth,
                captureQueueDepth: request.captureQueueDepth,
                enteredBitrate: request.enteredBitrate,
                bitrate: request.bitrate,
                latencyMode: latencyMode,
                performanceMode: performanceMode,
                allowRuntimeQualityAdjustment: request.allowRuntimeQualityAdjustment,
                lowLatencyHighResolutionCompressionBoost: request.lowLatencyHighResolutionCompressionBoost ?? true,
                disableResolutionCap: request.disableResolutionCap ?? false,
                streamScale: request.streamScale,
                audioConfiguration: audioConfiguration,
                targetFrameRate: targetFrameRate,
                bitrateAdaptationCeiling: request.bitrateAdaptationCeiling,
                encoderMaxWidth: request.encoderMaxWidth,
                encoderMaxHeight: request.encoderMaxHeight,
                mediaMaxPacketSize: acceptedMediaMaxPacketSize,
                upscalingMode: request.upscalingMode,
                codec: request.codec
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
            let failedMessage = DesktopStreamFailedMessage(
                reason: errorPayload.message,
                errorCode: errorPayload.code
            )
            do {
                try await clientContext.send(.desktopStreamFailed, content: failedMessage)
            } catch {
                // Fallback to generic error if the dedicated message fails
                if let response = try? ControlMessage(type: .error, content: errorPayload) {
                    clientContext.sendBestEffort(response)
                }
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
            if message.contains("Desktop stream already active") {
                return true
            }
            return message.contains("Virtual display acquisition failed for desktop stream:") ||
                message.contains("client disconnected during startup")
        }
        return false
    }

    private nonisolated static func formatBitrateForLogging(_ bitrate: Int) -> String {
        (Double(bitrate) / 1_000_000.0).formatted(.number.precision(.fractionLength(1))) + "Mbps"
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

    // MARK: - Host Display Resolution

    /// Query the host's current main display resolution in logical points.
    static func hostMainDisplayLogicalResolution() -> CGSize? {
        let mainDisplay = CGMainDisplayID()
        let modeLogicalResolution = CGVirtualDisplayBridge.currentDisplayModeSizes(mainDisplay)?.logical
        return resolvedHostLogicalDisplayResolution(
            bounds: CGDisplayBounds(mainDisplay),
            modeLogicalResolution: modeLogicalResolution
        )
    }
}

#endif
