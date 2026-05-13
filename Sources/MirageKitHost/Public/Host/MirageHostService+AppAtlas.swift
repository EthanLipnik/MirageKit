//
//  MirageHostService+AppAtlas.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/3/26.
//

import CoreGraphics
import Foundation
import MirageKit

#if os(macOS)
import ScreenCaptureKit

@MainActor
extension MirageHostService {
    struct AppAtlasStartedWindow {
        let session: MirageStreamSession
        let attachment: AppAtlasWindowAttachment
    }

    func startAppAtlasWindowCapture(
        app: MirageInstalledApp,
        window: MirageWindow,
        clientContext: ClientContext,
        selectRequest: SelectAppMessage,
        targetFrameRate: Int,
        requestedBitrate: Int?,
        mediaMaxPacketSize: Int
    ) async throws -> AppAtlasStartedWindow {
        let content = try await SCShareableContent.mirageHostContent()
        let disallowedWindowIDs = Set(activeStreamIDByWindowID.keys)
        let captureSource = try resolveCaptureSource(
            for: window,
            from: content,
            disallowedWindowIDs: disallowedWindowIDs,
            allowFallbackRemap: true
        )
        let scWindow = captureSource.window
        let scApplication = captureSource.application
        let resolvedWindowID = WindowID(scWindow.windowID)

        if let existingStreamID = activeStreamIDByWindowID[resolvedWindowID] {
            throw WindowStreamStartError.windowAlreadyBound(
                windowID: resolvedWindowID,
                existingStreamID: existingStreamID
            )
        }

        let logicalStreamID = nextStreamID
        nextStreamID += 1

        let resolvedWindowApplication = MirageApplication(
            id: scApplication.processID,
            bundleIdentifier: scApplication.bundleIdentifier,
            name: scApplication.applicationName
        )
        let latestFrame = currentWindowFrame(for: resolvedWindowID) ?? scWindow.frame
        let resolvedWindow = MirageWindow(
            id: resolvedWindowID,
            title: scWindow.title ?? window.title,
            application: resolvedWindowApplication,
            frame: latestFrame,
            isOnScreen: scWindow.isOnScreen,
            windowLayer: scWindow.windowLayer
        )

        let coordinator = try await ensureAppAtlasCoordinator(
            clientContext: clientContext,
            selectRequest: selectRequest,
            targetFrameRate: targetFrameRate,
            requestedBitrate: requestedBitrate,
            mediaMaxPacketSize: mediaMaxPacketSize
        )
        let attachment = try await coordinator.addWindow(
            streamID: logicalStreamID,
            window: resolvedWindow,
            windowWrapper: SCWindowWrapper(window: scWindow),
            applicationWrapper: SCApplicationWrapper(application: scApplication),
            displayWrapper: SCDisplayWrapper(display: captureSource.display)
        )

        let session = MirageStreamSession(
            id: logicalStreamID,
            window: resolvedWindow,
            client: clientContext.client
        )
        registerActiveStreamSession(session)
        inputStreamCache.set(logicalStreamID, window: resolvedWindow, client: clientContext.client)
        activateWindow(resolvedWindow)

        if let app = resolvedWindow.application {
            await startMenuBarMonitoring(streamID: logicalStreamID, app: app, clientContext: clientContext)
        }
        inputController.beginTrafficLightProtection(
            windowID: resolvedWindow.id,
            app: resolvedWindow.application,
            usesVirtualDisplay: false
        )
        await markAppStreamInteraction(streamID: logicalStreamID, reason: "app atlas window started")
        await syncAppListRequestDeferralForInteractiveWorkload()
        await updateLightsOutState()

        MirageLogger.host(
            "Started app-atlas logical window \(resolvedWindow.id) stream=\(logicalStreamID) media=\(attachment.mediaStreamID) app=\(app.bundleIdentifier)"
        )
        return AppAtlasStartedWindow(session: session, attachment: attachment)
    }

    func replaceAppAtlasWindowCapture(
        streamSession: MirageStreamSession,
        currentWindowID: WindowID,
        targetWindowID: WindowID,
        hiddenInfo: AppStreamHiddenWindowInfo,
        clientContext: ClientContext
    ) async throws -> AppAtlasStartedWindow {
        guard let coordinator = appAtlasCoordinatorsByClientID[clientContext.client.id] else {
            throw MirageError.protocolError("App-atlas coordinator is unavailable")
        }

        let requestedWindow = MirageWindow(
            id: targetWindowID,
            title: hiddenInfo.title,
            application: streamSession.window.application,
            frame: currentWindowFrame(for: targetWindowID) ?? CGRect(
                x: streamSession.window.frame.origin.x,
                y: streamSession.window.frame.origin.y,
                width: CGFloat(max(1, hiddenInfo.width)),
                height: CGFloat(max(1, hiddenInfo.height))
            ),
            isOnScreen: true,
            windowLayer: 0
        )
        let content = try await SCShareableContent.mirageHostContent()
        let disallowedWindowIDs = Set(activeStreamIDByWindowID.keys).subtracting([currentWindowID])
        let captureSource = try resolveCaptureSource(
            for: requestedWindow,
            from: content,
            disallowedWindowIDs: disallowedWindowIDs,
            allowFallbackRemap: false
        )
        let scWindow = captureSource.window
        let scApplication = captureSource.application
        let resolvedWindowID = WindowID(scWindow.windowID)
        guard resolvedWindowID == targetWindowID else {
            throw MirageError.windowNotFound
        }
        if let existingStreamID = activeStreamIDByWindowID[resolvedWindowID],
           existingStreamID != streamSession.id {
            throw WindowStreamStartError.windowAlreadyBound(
                windowID: resolvedWindowID,
                existingStreamID: existingStreamID
            )
        }

        let resolvedWindowApplication = MirageApplication(
            id: scApplication.processID,
            bundleIdentifier: scApplication.bundleIdentifier,
            name: scApplication.applicationName
        )
        let latestFrame = currentWindowFrame(for: resolvedWindowID) ?? scWindow.frame
        let resolvedWindow = MirageWindow(
            id: resolvedWindowID,
            title: scWindow.title ?? hiddenInfo.title,
            application: resolvedWindowApplication,
            frame: latestFrame,
            isOnScreen: scWindow.isOnScreen,
            windowLayer: scWindow.windowLayer
        )
        let attachment = try await coordinator.replaceWindow(
            streamID: streamSession.id,
            window: resolvedWindow,
            windowWrapper: SCWindowWrapper(window: scWindow),
            applicationWrapper: SCApplicationWrapper(application: scApplication),
            displayWrapper: SCDisplayWrapper(display: captureSource.display)
        )

        inputController.endTrafficLightProtection(windowID: currentWindowID)
        registerActiveStreamSession(
            MirageStreamSession(
                id: streamSession.id,
                window: resolvedWindow,
                client: streamSession.client
            )
        )
        inputStreamCache.set(streamSession.id, window: resolvedWindow, client: streamSession.client)
        activateWindow(resolvedWindow)

        if let app = resolvedWindow.application {
            await startMenuBarMonitoring(streamID: streamSession.id, app: app, clientContext: clientContext)
        }
        inputController.beginTrafficLightProtection(
            windowID: resolvedWindow.id,
            app: resolvedWindow.application,
            usesVirtualDisplay: false
        )
        await markAppStreamInteraction(streamID: streamSession.id, reason: "app atlas window replaced")
        await syncAppListRequestDeferralForInteractiveWorkload()
        await updateLightsOutState()

        MirageLogger.host(
            "Replaced app-atlas logical stream \(streamSession.id) window \(currentWindowID) -> \(resolvedWindowID) " +
                "media=\(attachment.mediaStreamID)"
        )
        let updatedSession = MirageStreamSession(
            id: streamSession.id,
            window: resolvedWindow,
            client: streamSession.client
        )
        return AppAtlasStartedWindow(session: updatedSession, attachment: attachment)
    }

}
#endif
