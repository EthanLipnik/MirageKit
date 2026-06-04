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
            let mediaPathPolicy = effectiveMediaPathPolicy(for: request, clientContext: clientContext)
            let acceptedMediaMaxPacketSize = mirageNegotiatedMediaMaxPacketSize(
                requested: request.mediaMaxPacketSize,
                mediaPathProfile: mediaPathPolicy.mediaPathProfile,
                pathKind: mediaPathPolicy.transportPathKind
            )
            let maxVisibleSlots = max(1, min(Self.appStreamMaxVisibleSlots, request.maxConcurrentVisibleWindows))
            let sharedBitrateBudget = resolvedAppSessionBitrateBudget(requestedBitrate: request.bitrate)
            MirageLogger.host("Latency mode: \(latencyMode.displayName)")
            MirageLogger.host("Host buffering policy: \(hostBufferingPolicy.rawValue)")
            MirageLogger
                .host(
                    "App stream slot cap: \(maxVisibleSlots), shared atlas bitrate budget: \(sharedBitrateBudget.map { "\($0) bps" } ?? "none")"
                )

            await refreshSessionStateIfNeeded()
            guard sessionState != .unavailable else {
                MirageLogger.host("Rejecting app stream while session is unavailable")
                await sendSessionState(to: clientContext)
                sendAppSelectionError(
                    to: clientContext,
                    code: .appStreamStartupFailed,
                    message: "The host session is unavailable.",
                    bundleIdentifier: request.bundleIdentifier
                )
                return
            }
            if sessionState.requiresCredentials {
                do {
                    try await acceptLockedAppStreamIntent(
                        request: request,
                        clientContext: clientContext,
                        targetFrameRate: targetFrameRate,
                        mediaPathPolicy: mediaPathPolicy,
                        mediaMaxPacketSize: acceptedMediaMaxPacketSize
                    )
                } catch {
                    MirageLogger.error(.host, error: error, message: "Failed to start locked app placeholder: ")
                    sendAppSelectionError(
                        to: clientContext,
                        code: .appStreamStartupFailed,
                        message: Self.appStreamStartupFailureMessage(appName: request.bundleIdentifier),
                        bundleIdentifier: request.bundleIdentifier
                    )
                }
                return
            }

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
                bitrateBudgetBps: sharedBitrateBudget
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
        if let pendingIntent = removePendingLockedAppStreamIntent(appSessionID: appSessionID) {
            MirageLogger.host("Cancelled pending locked app stream \(appSessionID.uuidString)")
            let placeholderStillReferenced = pendingLockedAppStreamIntentsByAppSessionID.values.contains {
                $0.placeholderDesktopStreamID == pendingIntent.placeholderDesktopStreamID
            }
            if pendingIntent.ownsPlaceholderDesktopStream,
               pendingIntent.placeholderDesktopStreamID == desktopStreamID,
               !placeholderStillReferenced {
                await stopDesktopStream(reason: .clientRequested)
            }
            return
        }
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

    private func acceptLockedAppStreamIntent(
        request: SelectAppMessage,
        clientContext: ClientContext,
        targetFrameRate: Int,
        mediaPathPolicy: MirageEffectiveMediaPathPolicy,
        mediaMaxPacketSize: Int
    ) async throws {
        let appSessionID = request.appSessionID
        if pendingLockedAppStreamIntentsByAppSessionID[appSessionID] == nil {
            pendingLockedAppStreamIntentOrder.append(appSessionID)
        }
        pendingLockedAppStreamIntentsByAppSessionID[appSessionID] = PendingLockedAppStreamIntent(
            request: request,
            clientSessionID: clientContext.sessionID,
            clientID: clientContext.client.id,
            createdAt: Date(),
            placeholderDesktopStreamID: desktopStreamID,
            placeholderDesktopSessionID: desktopSessionID,
            ownsPlaceholderDesktopStream: false,
            isResuming: false
        )

        guard desktopStreamID == nil else {
            try await sendLockedAppPlaceholderAnnouncementForActiveDesktop(
                request: request,
                clientContext: clientContext
            )
            MirageLogger.host(
                "Accepted locked app stream \(request.bundleIdentifier); reusing desktop placeholder stream \(desktopStreamID.map(String.init) ?? "nil")"
            )
            return
        }

        guard let displayWidth = request.displayWidth,
              let displayHeight = request.displayHeight else {
            throw MirageError.protocolError("Locked app placeholder requires display size")
        }

        do {
            try await startDesktopStream(
                to: clientContext,
                displayResolution: CGSize(width: displayWidth, height: displayHeight),
                clientScaleFactor: request.scaleFactor,
                mode: .secondary,
                cursorPresentation: .simulatedCursor,
                keyFrameInterval: request.keyFrameInterval,
                colorDepth: request.colorDepth,
                captureQueueDepth: request.captureQueueDepth,
                enteredBitrate: request.enteredBitrate,
                bitrate: request.bitrate,
                latencyMode: request.latencyMode ?? .lowestLatency,
                hostBufferingPolicy: request.resolvedHostBufferingPolicy,
                allowRuntimeQualityAdjustment: request.allowRuntimeQualityAdjustment,
                allowEncoderCatchUpQualityAdjustment: request.allowEncoderCatchUpQualityAdjustment,
                lowLatencyHighResolutionCompressionBoost: request.lowLatencyHighResolutionCompressionBoost ?? false,
                disableResolutionCap: request.disableResolutionCap ?? false,
                streamScale: nil,
                audioConfiguration: request.audioConfiguration ?? audioConfigurationByClientID[clientContext.client.id] ?? .default,
                targetFrameRate: targetFrameRate,
                bitrateAdaptationCeiling: request.bitrateAdaptationCeiling,
                encoderMaxWidth: request.encoderMaxWidth,
                encoderMaxHeight: request.encoderMaxHeight,
                mediaMaxPacketSize: mediaMaxPacketSize,
                mediaPathPolicy: mediaPathPolicy,
                upscalingMode: request.upscalingMode,
                codec: request.codec,
                startupRequestID: request.startupRequestID,
                presentationRole: .appStreamPlaceholder,
                associatedAppSessionID: request.appSessionID,
                associatedAppStartupRequestID: request.startupRequestID,
                associatedBundleIdentifier: request.bundleIdentifier
            )
            if var stored = pendingLockedAppStreamIntentsByAppSessionID[appSessionID] {
                stored.placeholderDesktopStreamID = desktopStreamID
                stored.placeholderDesktopSessionID = desktopSessionID
                stored.ownsPlaceholderDesktopStream = true
                pendingLockedAppStreamIntentsByAppSessionID[appSessionID] = stored
            }
            MirageLogger.host(
                "Accepted locked app stream \(request.bundleIdentifier); started desktop placeholder stream \(desktopStreamID.map(String.init) ?? "nil")"
            )
        } catch {
            _ = removePendingLockedAppStreamIntent(appSessionID: appSessionID)
            throw error
        }
    }

    private func sendLockedAppPlaceholderAnnouncementForActiveDesktop(
        request: SelectAppMessage,
        clientContext: ClientContext
    ) async throws {
        guard let streamID = desktopStreamID,
              let desktopSessionID,
              let desktopContext = desktopStreamContext else {
            throw MirageError.protocolError("Missing active desktop stream for locked app placeholder")
        }
        let streamStart = await desktopContext.streamStartSnapshot
        let displayPixelResolution = desktopCurrentGeometryDisplayPixelResolution ?? CGSize(
            width: streamStart.encodedDimensions.width,
            height: streamStart.encodedDimensions.height
        )
        let presentationResolution = desktopCurrentGeometryPresentationResolution ?? displayPixelResolution
        desktopPresentationGeneration &+= 1
        let message = DesktopStreamStartedMessage(
            streamID: streamID,
            desktopSessionID: desktopSessionID,
            width: Int(displayPixelResolution.width.rounded()),
            height: Int(displayPixelResolution.height.rounded()),
            frameRate: streamStart.targetFrameRate,
            codec: streamStart.codec,
            displayCount: 1,
            dimensionToken: streamStart.dimensionToken,
            acceptedMediaMaxPacketSize: streamStart.mediaMaxPacketSize,
            transitionPhase: .startup,
            desktopPresentationGeneration: desktopPresentationGeneration,
            captureSource: desktopCaptureSource,
            allowsClientResize: desktopCaptureSource != .mainDisplayFallback,
            acceptedDisplayScaleFactor: desktopCurrentGeometryDisplayScaleFactor ?? desktopRequestedScaleFactor,
            presentationWidth: Int(presentationResolution.width.rounded()),
            presentationHeight: Int(presentationResolution.height.rounded()),
            desktopGeometryContractID: desktopCurrentGeometryContractID,
            desktopGeometrySceneIdentity: desktopCurrentGeometrySceneIdentity,
            desktopGeometryDisplayPixelWidth: Int(displayPixelResolution.width.rounded()),
            desktopGeometryDisplayPixelHeight: Int(displayPixelResolution.height.rounded()),
            desktopGeometryEncodedPixelWidth: Int(streamStart.encodedDimensions.width),
            desktopGeometryEncodedPixelHeight: Int(streamStart.encodedDimensions.height),
            desktopGeometryRefreshTargetHz: desktopCurrentGeometryRefreshTargetHz ?? streamStart.targetFrameRate,
            presentationRole: .appStreamPlaceholder,
            associatedAppSessionID: request.appSessionID,
            associatedAppStartupRequestID: request.startupRequestID,
            associatedBundleIdentifier: request.bundleIdentifier
        )
        try await clientContext.send(.desktopStreamStarted, content: message)
    }

    func removePendingLockedAppStreamIntent(
        appSessionID: UUID
    ) -> PendingLockedAppStreamIntent? {
        let removed = pendingLockedAppStreamIntentsByAppSessionID.removeValue(forKey: appSessionID)
        pendingLockedAppStreamIntentOrder.removeAll { $0 == appSessionID }
        return removed
    }

    func removePendingLockedAppStreamIntents(clientID: UUID) {
        let appSessionIDs = pendingLockedAppStreamIntentsByAppSessionID
            .filter { $0.value.clientID == clientID }
            .map(\.key)
        for appSessionID in appSessionIDs {
            _ = removePendingLockedAppStreamIntent(appSessionID: appSessionID)
        }
    }

    func resumePendingLockedAppStreamIntentsIfNeeded() async {
        guard sessionState == .ready else { return }
        let orderedIDs = pendingLockedAppStreamIntentOrder
        for appSessionID in orderedIDs {
            guard var intent = pendingLockedAppStreamIntentsByAppSessionID[appSessionID],
                  !intent.isResuming else {
                continue
            }
            guard let clientContext = findClientContext(sessionID: intent.clientSessionID),
                  clientContext.client.id == intent.clientID,
                  !disconnectingClientIDs.contains(intent.clientID) else {
                _ = removePendingLockedAppStreamIntent(appSessionID: appSessionID)
                continue
            }
            intent.isResuming = true
            pendingLockedAppStreamIntentsByAppSessionID[appSessionID] = intent
            _ = removePendingLockedAppStreamIntent(appSessionID: appSessionID)
            do {
                let message = try ControlMessage(type: .selectApp, content: intent.request)
                await handleSelectApp(message, from: clientContext)
            } catch {
                MirageLogger.error(.host, error: error, message: "Failed to resume locked app stream intent: ")
                sendAppSelectionError(
                    to: clientContext,
                    code: .appStreamStartupFailed,
                    message: Self.appStreamStartupFailureMessage(appName: intent.request.bundleIdentifier),
                    bundleIdentifier: intent.request.bundleIdentifier
                )
            }
        }
    }
}

#endif
