//
//  MirageHostService+AppStreaming+Callbacks.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  App stream callbacks.
//

import Foundation
import MirageKit

#if os(macOS)
import AppKit

@MainActor
extension MirageHostService {
    func findClientContext(clientID: UUID) -> ClientContext? {
        clientsByConnection.values.first { $0.client.id == clientID }
    }

    func setupAppStreamManagerCallbacks() {
        Task { @MainActor [weak self] in
            guard let self else { return }

            await appStreamManager.setOnNewWindowDetected { [weak self] bundleID, scWindow in
                let windowID = WindowID(scWindow.windowID)
                Task { @MainActor in
                    await self?.handleNewWindowFromStreamedApp(bundleID: bundleID, windowID: windowID)
                }
            }

            await appStreamManager.setOnWindowClosed { [weak self] bundleID, windowID in
                Task { @MainActor in
                    await self?.handleWindowClosedFromStreamedApp(bundleID: bundleID, windowID: windowID)
                }
            }

            await appStreamManager.setOnAppTerminated { [weak self] bundleID in
                Task { @MainActor in
                    await self?.handleStreamedAppTerminated(bundleID: bundleID)
                }
            }
        }
    }

    func handleNewWindowFromStreamedApp(bundleID: String, windowID: WindowID) async {
        guard let initialSession = await appStreamManager.getSession(bundleIdentifier: bundleID),
              case .streaming = initialSession.state,
              let initialClientContext = findClientContext(clientID: initialSession.clientID) else {
            return
        }

        // Ignore duplicate add signals for windows already tracked in-session.
        if initialSession.windowStreams[windowID] != nil { return }

        let existingStreamID = initialSession.windowStreams.values.map(\.streamID).max()
        let existingContext = existingStreamID.flatMap { streamsByID[$0] }
        let streamScale = await existingContext?.getStreamScale() ?? 1.0
        let encoderSettings = await existingContext?.getEncoderSettings()
        let targetFrameRate = await existingContext?.getTargetFrameRate()
        let audioConfiguration = audioConfigurationByClientID[initialSession.clientID] ?? .default
        let disableResolutionCap = await existingContext?.isResolutionCapDisabled() ?? false
        let inheritedClientScaleFactor = existingStreamID.flatMap { clientVirtualDisplayScaleFactor(streamID: $0) }

        try? await refreshWindows()
        guard let mirageWindow = availableWindows.first(where: { $0.id == windowID }) else {
            await emitWindowStreamFailed(
                to: initialClientContext,
                bundleIdentifier: bundleID,
                windowID: windowID,
                title: nil,
                reason: "Window disappeared before stream startup"
            )
            await endAppSessionIfIdle(bundleIdentifier: bundleID)
            return
        }

        guard let liveSession = await appStreamManager.getSession(bundleIdentifier: bundleID),
              case .streaming = liveSession.state,
              liveSession.clientID == initialSession.clientID,
              !disconnectingClientIDs.contains(liveSession.clientID),
              let clientContext = findClientContext(clientID: liveSession.clientID) else {
            return
        }

        let preferredDisplayResolution: CGSize = {
            if liveSession.requestedDisplayResolution.width > 0, liveSession.requestedDisplayResolution.height > 0 {
                return liveSession.requestedDisplayResolution
            }
            if let inheritedBoundsSize = existingStreamID.flatMap({ getVirtualDisplayState(streamID: $0)?.bounds.size }),
               inheritedBoundsSize.width > 0,
               inheritedBoundsSize.height > 0 {
                return inheritedBoundsSize
            }
            return mirageWindow.frame.size
        }()
        let preferredClientScaleFactor = liveSession.requestedClientScaleFactor ?? inheritedClientScaleFactor

        do {
            let streamSession = try await startStream(
                for: mirageWindow,
                to: clientContext.client,
                dataPort: nil,
                clientDisplayResolution: preferredDisplayResolution,
                clientScaleFactor: preferredClientScaleFactor,
                keyFrameInterval: encoderSettings?.keyFrameInterval,
                streamScale: streamScale,
                targetFrameRate: targetFrameRate,
                bitDepth: encoderSettings?.bitDepth,
                captureQueueDepth: encoderSettings?.captureQueueDepth,
                bitrate: encoderSettings?.bitrate,
                latencyMode: encoderSettings?.latencyMode ?? .auto,
                performanceMode: encoderSettings?.performanceMode ?? .standard,
                lowLatencyHighResolutionCompressionBoost: encoderSettings?
                    .lowLatencyHighResolutionCompressionBoostEnabled ?? true,
                disableResolutionCap: disableResolutionCap,
                audioConfiguration: audioConfiguration
            )

            guard let confirmedSession = await appStreamManager.getSession(bundleIdentifier: bundleID),
                  case .streaming = confirmedSession.state,
                  confirmedSession.clientID == liveSession.clientID else {
                await stopStream(streamSession, minimizeWindow: false, updateAppSession: false)
                return
            }

            let isResizable = await appStreamManager.checkWindowResizability(
                windowID: windowID,
                processID: mirageWindow.application?.id ?? 0
            )

            await appStreamManager.addWindowToSession(
                bundleIdentifier: bundleID,
                windowID: windowID,
                streamID: streamSession.id,
                title: streamSession.window.title,
                width: Int(streamSession.window.frame.width),
                height: Int(streamSession.window.frame.height),
                isResizable: isResizable
            )

            let response = WindowAddedToStreamMessage(
                bundleIdentifier: bundleID,
                streamID: streamSession.id,
                windowID: windowID,
                title: streamSession.window.title,
                width: Int(streamSession.window.frame.width),
                height: Int(streamSession.window.frame.height),
                isResizable: isResizable
            )
            try? await clientContext.send(.windowAddedToStream, content: response)

            MirageLogger.host("Added new window \(windowID) to app stream \(bundleID)")
        } catch {
            let detail = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            let reason = detail.isEmpty ? String(describing: error) : detail
            await emitWindowStreamFailed(
                to: clientContext,
                bundleIdentifier: bundleID,
                windowID: windowID,
                title: mirageWindow.title,
                reason: reason
            )
            MirageLogger.error(.host, error: error, message: "Failed to start stream for new window: ")
            await endAppSessionIfIdle(bundleIdentifier: bundleID)
        }
    }

    func handleWindowClosedFromStreamedApp(bundleID: String, windowID: WindowID) async {
        guard let session = await appStreamManager.getSession(bundleIdentifier: bundleID),
              let clientContext = findClientContext(clientID: session.clientID) else {
            return
        }

        let windowInfo = session.windowStreams[windowID]

        if let streamID = windowInfo?.streamID,
           let streamSession = activeStreams.first(where: { $0.id == streamID }) {
            await stopStream(streamSession, minimizeWindow: false, updateAppSession: false)
        }

        if windowInfo != nil {
            await appStreamManager.removeWindowFromSession(
                bundleIdentifier: bundleID,
                windowID: windowID
            )

            await emitWindowRemovedFromStream(
                to: clientContext,
                bundleIdentifier: bundleID,
                windowID: windowID,
                reason: .noLongerEligible
            )
        }

        await endAppSessionIfIdle(bundleIdentifier: bundleID)
        MirageLogger.host("Removed window \(windowID) from app stream \(bundleID)")
    }

    func handleStreamedAppTerminated(bundleID: String) async {
        guard let session = await appStreamManager.getSession(bundleIdentifier: bundleID),
              let clientContext = findClientContext(clientID: session.clientID) else {
            return
        }

        inputController.clearAllModifiers()

        let closedWindowIDs = session.windowStreams.keys.sorted(by: <)

        for windowID in closedWindowIDs {
            if let windowInfo = session.windowStreams[windowID],
               let streamSession = activeStreams.first(where: { $0.id == windowInfo.streamID }) {
                await stopStream(streamSession, minimizeWindow: false, updateAppSession: false)
            }

            await emitWindowRemovedFromStream(
                to: clientContext,
                bundleIdentifier: bundleID,
                windowID: windowID,
                reason: .appTerminated
            )
        }

        let allSessions = await appStreamManager.getAllSessions()
        let hasRemainingWindows = allSessions.contains { candidate in
            candidate.bundleIdentifier.lowercased() != bundleID.lowercased() &&
                candidate.clientID == session.clientID &&
                !candidate.windowStreams.isEmpty
        }

        let terminated = AppTerminatedMessage(
            bundleIdentifier: bundleID,
            closedWindowIDs: closedWindowIDs,
            hasRemainingWindows: hasRemainingWindows
        )
        try? await clientContext.send(.appTerminated, content: terminated)

        await appStreamManager.endSession(bundleIdentifier: bundleID)
        await restoreStageManagerAfterAppStreamingIfNeeded()

        MirageLogger.host("App \(bundleID) terminated, ended session")
    }

    func emitWindowRemovedFromStream(
        to clientContext: ClientContext,
        bundleIdentifier: String,
        windowID: WindowID,
        reason: WindowRemovedFromStreamMessage.RemovalReason
    ) async {
        let response = WindowRemovedFromStreamMessage(
            bundleIdentifier: bundleIdentifier,
            windowID: windowID,
            reason: reason
        )
        try? await clientContext.send(.windowRemovedFromStream, content: response)
    }

    func emitWindowStreamFailed(
        to clientContext: ClientContext,
        bundleIdentifier: String,
        windowID: WindowID,
        title: String?,
        reason: String
    ) async {
        let message = WindowStreamFailedMessage(
            bundleIdentifier: bundleIdentifier,
            windowID: windowID,
            title: title,
            reason: reason
        )
        try? await clientContext.send(.windowStreamFailed, content: message)
    }
}

#endif
