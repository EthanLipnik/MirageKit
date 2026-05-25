//
//  MirageHostService+AppStreaming+Requests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  App stream request handling.
//

import Foundation
import MirageKit

#if os(macOS)
@MainActor
extension MirageHostService {
    /// Handles a client's request to start streaming an application's windows.
    func handleSelectApp(
        _ message: ControlMessage,
        from clientContext: ClientContext
    )
    async {
        var pendingLightsOutSetup = false
        do {
            let request = try message.decode(SelectAppMessage.self)
            let client = clientContext.client
            guard beginStreamSetup(
                clientSessionID: clientContext.sessionID,
                startupRequestID: request.startupRequestID
            ) else {
                MirageLogger.host("Ignoring cancelled selectApp setup before side effects")
                return
            }
            defer {
                finishStreamSetup(
                    clientSessionID: clientContext.sessionID,
                    startupRequestID: request.startupRequestID
                )
            }
            guard !disconnectingClientIDs.contains(client.id),
                  clientsByID[client.id] != nil else {
                MirageLogger.host("Ignoring selectApp from disconnected client \(client.name)")
                return
            }
            MirageLogger.host("Client \(client.name) selected app: \(request.bundleIdentifier)")
            await pruneOrphanedAppSessions()

            let targetFrameRate = resolvedTargetFrameRate(request.targetFrameRate)
            MirageLogger.host("Frame rate: \(targetFrameRate)fps")

            let latencyMode = request.latencyMode ?? .lowestLatency
            let hostBufferingPolicy = request.resolvedHostBufferingPolicy
            guard let displayWidth = request.displayWidth,
                  let displayHeight = request.displayHeight,
                  displayWidth > 0,
                  displayHeight > 0 else {
                MirageLogger.host("Rejecting app stream request without display size")
                let error = ErrorMessage(
                    code: .invalidMessage,
                    message: "App streaming requires displayWidth/displayHeight"
                )
                clientContext.queueBestEffort(.error, content: error)
                return
            }
            let requestedDisplayResolution = CGSize(width: displayWidth, height: displayHeight)
            let pathKind = clientContext.pathSnapshot.map { MirageNetworkPathClassifier.classify($0).kind }
            let acceptedMediaMaxPacketSize = mirageNegotiatedMediaMaxPacketSize(
                requested: request.mediaMaxPacketSize,
                pathKind: pathKind
            )
            let maxVisibleSlots = max(1, min(Self.appStreamMaxVisibleSlots, request.maxConcurrentVisibleWindows))
            let sharedBitrateBudget = resolvedAppSessionBitrateBudget(requestedBitrate: request.bitrate)
            let bitrateAllocationPolicy = request.bitrateAllocationPolicy ?? .prioritizeActiveWindow
            MirageLogger.host("Latency mode: \(latencyMode.displayName)")
            MirageLogger.host("Host buffering policy: \(hostBufferingPolicy.rawValue)")
            MirageLogger
                .host(
                    "App stream slot cap: \(maxVisibleSlots), shared bitrate budget: \(sharedBitrateBudget.map { "\($0) bps" } ?? "none"), allocationPolicy: \(bitrateAllocationPolicy.rawValue)"
                )

            let apps = await appStreamManager.installedApps(includeIcons: false)
            guard let app = apps
                .first(where: { $0.bundleIdentifier.lowercased() == request.bundleIdentifier.lowercased() }) else {
                MirageLogger.host("App \(request.bundleIdentifier) not found")
                sendAppSelectionError(to: clientContext, code: .windowNotFound, message: "App not found: \(request.bundleIdentifier)")
                return
            }

            if await handleExistingAppSessionExpansionIfNeeded(
                SelectAppExistingSessionExpansionRequest(
                    app: app,
                    client: client,
                    clientContext: clientContext,
                    selectRequest: request,
                    maxVisibleSlots: maxVisibleSlots,
                    targetFrameRate: targetFrameRate,
                    mediaMaxPacketSize: acceptedMediaMaxPacketSize
                )
            ) {
                return
            }

            pendingLightsOutSetup = true
            await beginPendingAppStreamLightsOutSetup()
            await prepareStageManagerForAppStreamingIfNeeded()

            guard await appStreamManager.startAppSession(
                id: request.appSessionID,
                bundleIdentifier: app.bundleIdentifier,
                appName: app.name,
                appPath: app.path,
                clientID: client.id,
                clientName: client.name,
                requestedDisplayResolution: requestedDisplayResolution,
                requestedClientScaleFactor: request.scaleFactor,
                maxVisibleSlots: maxVisibleSlots,
                bitrateBudgetBps: sharedBitrateBudget,
                bitrateAllocationPolicy: bitrateAllocationPolicy
            ) != nil else {
                MirageLogger.host("Failed to start app session for \(app.name)")
                sendAppSelectionError(
                    to: clientContext,
                    code: .windowNotFound,
                    message: "\(app.name) is already being streamed to another client"
                )
                await restoreStageManagerAfterAppStreamingIfNeeded()
                pendingLightsOutSetup = false
                await endPendingAppStreamLightsOutSetup()
                return
            }

            if isStreamSetupCancelled(clientSessionID: clientContext.sessionID, startupRequestID: request.startupRequestID) {
                MirageLogger.host("App stream setup cancelled by client before launch for \(app.name)")
                await appStreamManager.endSession(appSessionID: request.appSessionID)
                await restoreStageManagerAfterAppStreamingIfNeeded()
                pendingLightsOutSetup = false
                await endPendingAppStreamLightsOutSetup()
                return
            }

            let launchOutcome = await appStreamManager.launchAppIfNeeded(app.bundleIdentifier, path: app.path)
            if isStreamSetupCancelled(clientSessionID: clientContext.sessionID, startupRequestID: request.startupRequestID) {
                MirageLogger.host("App stream setup cancelled by client after launch for \(app.name)")
                await appStreamManager.endSession(appSessionID: request.appSessionID)
                await restoreStageManagerAfterAppStreamingIfNeeded()
                pendingLightsOutSetup = false
                await endPendingAppStreamLightsOutSetup()
                return
            }
            guard launchOutcome != .failed else {
                MirageLogger.host("Failed to launch app \(app.name)")
                await appStreamManager.endSession(bundleIdentifier: app.bundleIdentifier)
                sendAppSelectionError(
                    to: clientContext,
                    code: .appStreamStartupFailed,
                    message: Self.appStreamStartupFailureMessage(appName: app.name),
                    bundleIdentifier: app.bundleIdentifier
                )
                await restoreStageManagerAfterAppStreamingIfNeeded()
                pendingLightsOutSetup = false
                await endPendingAppStreamLightsOutSetup()
                return
            }

            let startupResult = await startInitialAppWindowStreams(
                app: app,
                client: client,
                selectRequest: request,
                targetFrameRate: targetFrameRate,
                mediaMaxPacketSize: acceptedMediaMaxPacketSize,
                launchOutcome: launchOutcome
            )
            if isStreamSetupCancelled(clientSessionID: clientContext.sessionID, startupRequestID: request.startupRequestID) {
                MirageLogger.host("App stream setup cancelled by client; ending session for \(app.name)")
                for window in startupResult.windows {
                    if let session = activeStreams.first(where: { $0.id == window.streamID }) {
                        await stopStream(session, updateAppSession: false)
                    }
                }
                await appStreamManager.endSession(bundleIdentifier: app.bundleIdentifier)
                await restoreStageManagerAfterAppStreamingIfNeeded()
                pendingLightsOutSetup = false
                await endPendingAppStreamLightsOutSetup()
                return
            }

            guard !startupResult.windows.isEmpty else {
                MirageLogger.host(
                    "No window streams started for \(app.name); ending session (reason: \(startupResult.failureSummary))"
                )
                await appStreamManager.endSession(bundleIdentifier: app.bundleIdentifier)
                await restoreStageManagerAfterAppStreamingIfNeeded()
                sendAppSelectionError(
                    to: clientContext,
                    code: .appStreamStartupFailed,
                    message: Self.appStreamStartupFailureMessage(appName: app.name),
                    bundleIdentifier: app.bundleIdentifier
                )
                pendingLightsOutSetup = false
                await endPendingAppStreamLightsOutSetup()
                return
            }

            try await sendInitialAppStreamStarted(
                app: app,
                request: request,
                startupWindows: startupResult.windows,
                clientContext: clientContext
            )

            pendingLightsOutSetup = false
            await endPendingAppStreamLightsOutSetup()
            MirageLogger.host("Started streaming \(app.name) with \(startupResult.windows.count) initial window(s)")
        } catch {
            if pendingLightsOutSetup {
                pendingLightsOutSetup = false
                await endPendingAppStreamLightsOutSetup()
            }
            MirageLogger.error(.host, error: error, message: "Failed to handle select app: ")
        }
    }

    /// Cancels a partially-started app session and releases any streams it already opened.
    func cancelStartingAppSession(appSessionID: UUID) async {
        guard let session = await appStreamManager.session(appSessionID: appSessionID) else { return }
        guard session.state == .starting || session.state == .streaming else { return }
        MirageLogger.host("Cancelling starting app session \(appSessionID.uuidString) for \(session.appName)")
        for info in session.windowStreams.values {
            if let streamSession = activeStreams.first(where: { $0.id == info.streamID }) {
                await stopStream(streamSession, updateAppSession: false)
            }
        }
        await appStreamManager.endSession(appSessionID: appSessionID)
        await restoreStageManagerAfterAppStreamingIfNeeded()
        await endPendingAppStreamLightsOutSetup()
    }
}

#endif
