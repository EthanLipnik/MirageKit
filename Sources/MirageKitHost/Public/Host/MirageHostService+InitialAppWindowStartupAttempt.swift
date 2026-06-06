//
//  MirageHostService+InitialAppWindowStartupAttempt.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/9/26.
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
import Foundation

#if os(macOS)
@MainActor
extension MirageHostService {
    /// Starts capture for a resolved app window and binds it into the app session.
    func attemptStartInitialAppWindowStream(
        app: MirageWire.MirageInstalledApp,
        startupCandidate: AppStreamWindowCandidate,
        preferredWindow: MirageMedia.MirageWindow,
        preferredSlotIndex: Int,
        clientContext: ClientContext,
        selectRequest: MirageWire.SelectAppMessage,
        targetFrameRate: Int,
        requestedBitrateOverride: Int?,
        mediaMaxPacketSize: Int
    ) async throws -> InitialStartedAppWindow {
        let started = try await startAppAtlasWindowCapture(
            app: app,
            window: preferredWindow,
            clientContext: clientContext,
            selectRequest: selectRequest,
            targetFrameRate: targetFrameRate,
            requestedBitrate: requestedBitrateOverride ?? selectRequest.bitrate,
            mediaMaxPacketSize: mediaMaxPacketSize
        )
        guard !isStreamSetupCancelled(
            clientSessionID: clientContext.sessionID,
            startupRequestID: selectRequest.startupRequestID
        ) else {
            await stopStream(started.session, minimizeWindow: false, updateAppSession: false)
            throw CancellationError()
        }

        let streamSession = started.session
        let attachment = started.attachment
        let resolvedWindow = streamSession.window
        let processID = resolvedWindow.application?.id ?? preferredWindow.application?.id ?? startupCandidate.window.application?.id ?? 0
        let isResizable = appStreamManager.checkWindowResizability(
            processID: processID
        )

        if let existingStreamID = await appStreamManager.streamIDForWindow(
            bundleIdentifier: app.bundleIdentifier,
            windowID: resolvedWindow.id
        ), existingStreamID != streamSession.id {
            await stopStream(streamSession, minimizeWindow: false, updateAppSession: false)
            throw WindowStreamStartError.windowAlreadyBound(
                windowID: resolvedWindow.id,
                existingStreamID: existingStreamID
            )
        }

        guard await appStreamManager.addWindowToSession(
            bundleIdentifier: app.bundleIdentifier,
            windowID: resolvedWindow.id,
            streamID: streamSession.id,
            title: resolvedWindow.title,
            width: Int(resolvedWindow.frame.width),
            height: Int(resolvedWindow.frame.height),
            isResizable: isResizable,
            slotIndex: preferredSlotIndex,
            mediaStreamID: attachment.mediaStreamID,
            atlasRegion: attachment.atlasRegion
        ) != nil else {
            let existingStreamID = await appStreamManager.streamIDForWindow(
                bundleIdentifier: app.bundleIdentifier,
                windowID: resolvedWindow.id
            )
            await stopStream(streamSession, minimizeWindow: false, updateAppSession: false)
            if let existingStreamID {
                throw WindowStreamStartError.windowAlreadyBound(
                    windowID: resolvedWindow.id,
                    existingStreamID: existingStreamID
                )
            }
            throw MirageCore.MirageError.protocolError(
                "Failed to bind startup window \(resolvedWindow.id) into slot \(preferredSlotIndex)"
            )
        }

        if let context = streamsByID[streamSession.id] {
            await appStreamManager.setCapturedClusterWindowIDs(
                bundleIdentifier: app.bundleIdentifier,
                streamID: streamSession.id,
                capturedClusterWindowIDs: context.capturedWindowClusterWindowIDs
            )
        }

        return InitialStartedAppWindow(
            streamID: streamSession.id,
            mediaStreamID: attachment.mediaStreamID,
            windowID: resolvedWindow.id,
            title: resolvedWindow.title,
            width: Int(resolvedWindow.frame.width),
            height: Int(resolvedWindow.frame.height),
            isResizable: isResizable,
            atlasRegion: attachment.atlasRegion,
            atlasLayouts: attachment.atlasLayouts
        )
    }

    /// Returns a display title for startup failure messages.
    func initialStreamFailureTitle(for candidate: AppStreamWindowCandidate, appName: String) -> String {
        if let title = candidate.window.title?.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty {
            return title
        }
        return "\(appName) window #\(candidate.window.id)"
    }

    /// Queues a best-effort app selection error response for the requesting client.
    func sendAppSelectionError(
        to clientContext: ClientContext,
        code: MirageWire.ErrorMessage.ErrorCode,
        message: String,
        bundleIdentifier: String? = nil
    ) {
        let error = MirageWire.ErrorMessage(code: code, message: message, bundleIdentifier: bundleIdentifier)
        clientContext.queueBestEffort(.error, content: error)
    }
}

#endif
