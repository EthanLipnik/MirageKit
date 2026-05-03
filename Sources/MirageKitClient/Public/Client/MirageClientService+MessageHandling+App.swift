//
//  MirageClientService+MessageHandling+App.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  App-centric streaming message handling.
//

import Foundation
import ImageIO
import MirageKit

@MainActor
extension MirageClientService {
    func handleAppListProgress(_ message: ControlMessage) async {
        guard controlUpdatePolicy != .interactiveStreaming else {
            deferredControlRefreshRequirements.needsAppListRefresh = true
            return
        }
        do {
            let progress = try message.decode(AppListProgressMessage.self)
            guard activeAppListRequestID == progress.requestID else {
                MirageLogger.client(
                    "Ignoring app-list progress for stale requestID=\(progress.requestID.uuidString)"
                )
                return
            }
            guard !progress.apps.isEmpty else { return }
            heartbeatGraceDeadline = ContinuousClock.now + .seconds(20)

            let previousIconsByBundleIdentifier = availableIconPayloadsByBundleIdentifierSnapshot()
            let preparedProgress = await Task.detached(priority: .userInitiated) {
                Self.prepareAppListProgressApps(
                    progress.apps,
                    previousIconsByBundleIdentifier: previousIconsByBundleIdentifier
                )
            }.value

            for rejectedIcon in preparedProgress.rejectedIcons {
                MirageLogger.client(
                    "Rejected app-list icon payload due to \(rejectedIcon.reason.logDescription) for bundleID=\(rejectedIcon.bundleIdentifier)"
                )
            }

            for app in preparedProgress.apps {
                let normalizedBundleID = app.bundleIdentifier.lowercased()
                guard !normalizedBundleID.isEmpty else { continue }
                if activeAppListReceivedBundleIdentifiers.insert(normalizedBundleID).inserted,
                   !orderedAvailableAppBundleIdentifiers.contains(normalizedBundleID) {
                    orderedAvailableAppBundleIdentifiers.append(normalizedBundleID)
                }
                availableAppsByBundleIdentifier[normalizedBundleID] = app
            }

            availableApps = orderedAvailableAppBundleIdentifiers.compactMap {
                availableAppsByBundleIdentifier[$0]
            }
            onAppListProgress?(availableApps)
        } catch {
            MirageLogger.error(.client, error: error, message: "Failed to decode app-list progress: ")
        }
    }

    func handleAppListComplete(_ message: ControlMessage) {
        guard controlUpdatePolicy != .interactiveStreaming else {
            deferredControlRefreshRequirements.needsAppListRefresh = true
            return
        }
        do {
            let complete = try message.decode(AppListCompleteMessage.self)
            guard activeAppListRequestID == complete.requestID else {
                MirageLogger.client(
                    "Ignoring app-list completion for stale requestID=\(complete.requestID.uuidString)"
                )
                return
            }
            heartbeatGraceDeadline = nil

            let completedBundleIdentifiers = orderedAvailableAppBundleIdentifiers.filter {
                activeAppListReceivedBundleIdentifiers.contains($0)
            }
            availableApps = completedBundleIdentifiers.compactMap {
                availableAppsByBundleIdentifier[$0]
            }
            rebuildAvailableAppAccumulator(from: availableApps)
            activeAppListReceivedBundleIdentifiers.removeAll(keepingCapacity: true)
            hasReceivedAppList = true
            if availableApps.count != complete.totalAppCount {
                MirageLogger.client(
                    "App-list completion count mismatch requestID=\(complete.requestID.uuidString) received=\(availableApps.count) total=\(complete.totalAppCount)"
                )
            }
            MirageLogger.client(
                "Received app-list completion with \(complete.totalAppCount) apps requestID=\(complete.requestID.uuidString)"
            )
            onAppListReceived?(availableApps)
        } catch {
            MirageLogger.error(.client, error: error, message: "Failed to decode app-list completion: ")
        }
    }

    func handleHostHardwareIcon(_ message: ControlMessage) {
        do {
            let hostIcon = try message.decode(HostHardwareIconMessage.self)
            guard let hostID = connectedHost?.deviceID else {
                MirageLogger.client("Ignoring host hardware icon payload without a connected host ID")
                return
            }

            onHostHardwareIconReceived?(
                hostID,
                hostIcon.pngData,
                hostIcon.iconName,
                hostIcon.hardwareModelIdentifier,
                hostIcon.hardwareMachineFamily
            )
            MirageLogger.client(
                "Received host hardware icon payload bytes=\(hostIcon.pngData.count) icon=\(hostIcon.iconName ?? "nil") family=\(hostIcon.hardwareMachineFamily ?? "nil")"
            )
        } catch {
            MirageLogger.error(.client, error: error, message: "Failed to decode host hardware icon: ")
        }
    }

    func handleHostWallpaper(_ message: ControlMessage) {
        let interval = MirageLogger.beginInterval(.client, "HostWallpaper.Receive")
        defer {
            MirageLogger.endInterval(interval)
        }

        do {
            let wallpaper = try message.decode(HostWallpaperMessage.self)
            guard let requestID = wallpaper.requestID,
                  requestID == hostWallpaperRequestID else {
                MirageLogger.client("Ignoring stale host wallpaper response")
                return
            }

            if let errorMessage = wallpaper.errorMessage,
               !errorMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                MirageLogger.client("Host wallpaper request failed: \(errorMessage)")
                completeHostWallpaperRequest(
                    .failure(MirageError.protocolError(errorMessage))
                )
                return
            }

            guard let imageData = wallpaper.imageData,
                  !imageData.isEmpty,
                  let hostID = connectedHost?.deviceID else {
                MirageLogger.client("Ignoring incomplete host wallpaper payload")
                completeHostWallpaperRequest(
                    .failure(MirageError.protocolError("Host wallpaper payload was empty"))
                )
                return
            }

            onHostWallpaperReceived?(
                hostID,
                imageData,
                wallpaper.pixelWidth,
                wallpaper.pixelHeight,
                wallpaper.bytesPerPixelEstimate
            )
            MirageLogger.client(
                "Received host wallpaper payload requestID=\(requestID.uuidString.lowercased()) bytes=\(imageData.count) size=\(wallpaper.pixelWidth)x\(wallpaper.pixelHeight)"
            )
            completeHostWallpaperRequest(.success(()))
        } catch {
            MirageLogger.error(.client, error: error, message: "Failed to decode host wallpaper: ")
            completeHostWallpaperRequest(.failure(error))
        }
    }

    func handleAppStreamStarted(_ message: ControlMessage) {
        do {
            let started = try message.decode(AppStreamStartedMessage.self)
            MirageLogger.client("App stream started: \(started.appName) with \(started.windows.count) windows")
            streamingAppBundleID = started.bundleIdentifier
            appWindowInventory = nil
            storeAppAtlasLayouts(started.atlasLayouts)
            onAppStreamStarted?(started)
        } catch {
            MirageLogger.error(.client, error: error, message: "Failed to decode app stream started: ")
        }
    }

    func handleAppAtlasMediaUpdate(_ message: ControlMessage) async {
        do {
            let update = try message.decode(AppAtlasMediaUpdateMessage.self)
            let mediaStreamID = update.mediaStreamID
            guard shouldAcceptStartupAttempt(update.startupAttemptID, for: mediaStreamID) else {
                MirageLogger.client(
                    "Ignoring stale appAtlasMediaUpdate for media stream \(mediaStreamID) startupAttemptID=\(update.startupAttemptID.uuidString)"
                )
                return
            }

            storeAppAtlasLayout(update.layout)
            activeStreamCodecs[mediaStreamID] = update.codec
            appStreamStartAcknowledgementByStreamID[mediaStreamID] = StreamStartAcknowledgement(
                width: update.width,
                height: update.height,
                dimensionToken: update.dimensionToken
            )

            let hasController = controllersByStream[mediaStreamID] != nil
            let isExistingStream = activeStreamIDsForFiltering.contains(mediaStreamID) || hasController
            let previousDimensionToken = appDimensionTokenByStream[mediaStreamID]
            let acceptedMediaMaxPacketSize = resolvedAcceptedMediaMaxPacketSize(update.acceptedPacketSize)
            let previousMediaMaxPacketSize = mediaMaxPacketSizeByStream[mediaStreamID] ?? mirageDefaultMaxPacketSize
            let packetSizeChanged = hasController && previousMediaMaxPacketSize != acceptedMediaMaxPacketSize
            let resetDecision = appStreamStartResetDecision(
                streamID: mediaStreamID,
                isExistingStream: isExistingStream,
                hasController: hasController,
                requestStartPending: false,
                previousDimensionToken: previousDimensionToken,
                receivedDimensionToken: update.dimensionToken
            )
            let shouldSetupController = resetDecision == .resetController || packetSizeChanged || !hasController

            if let dimensionToken = update.dimensionToken {
                appDimensionTokenByStream[mediaStreamID] = dimensionToken
            }
            registerStartupAttempt(update.startupAttemptID, for: mediaStreamID)

            if shouldSetupController {
                streamStartupBaseTimes[mediaStreamID] = CFAbsoluteTimeGetCurrent()
                streamStartupFirstRegistrationSent.remove(mediaStreamID)
                streamStartupFirstPacketReceived.remove(mediaStreamID)
                markStartupPacketPending(mediaStreamID)
                await setupControllerForStream(
                    mediaStreamID,
                    codec: update.codec,
                    streamDimensions: (width: update.width, height: update.height),
                    mediaMaxPacketSize: acceptedMediaMaxPacketSize,
                    dimensionToken: update.dimensionToken,
                    forwardsResizeEvents: false
                )
            } else if let dimensionToken = update.dimensionToken,
                      let controller = controllersByStream[mediaStreamID] {
                let reassembler = await controller.getReassembler()
                reassembler.updateExpectedDimensionToken(dimensionToken)
                await controller.setDecoderCodec(
                    update.codec,
                    streamDimensions: (width: update.width, height: update.height)
                )
            }

            addActiveStreamID(mediaStreamID)
            registeredStreamIDs.insert(mediaStreamID)
            await updateReassemblerSnapshot()
            await sendStreamReadyAck(
                streamID: mediaStreamID,
                startupAttemptID: update.startupAttemptID,
                kind: .appAtlas
            )
            if shouldSetupController {
                startStartupRegistrationRetry(streamID: mediaStreamID)
            }
            MirageLogger.client(
                "App-atlas media updated stream=\(mediaStreamID) size=\(update.width)x\(update.height) layoutEpoch=\(update.layoutEpoch)"
            )
        } catch {
            MirageLogger.error(.client, error: error, message: "Failed to decode app-atlas media update: ")
        }
    }

    func handleAppWindowInventory(_ message: ControlMessage) {
        do {
            let inventory = try message.decode(AppWindowInventoryMessage.self)
            storeAppAtlasLayouts(inventory.atlasLayouts)
            appWindowInventory = inventory
            onAppWindowInventoryUpdate?(inventory)
        } catch {
            MirageLogger.error(.client, error: error, message: "Failed to decode app window inventory: ")
        }
    }

    func handleAppWindowCloseBlockedAlert(_ message: ControlMessage) {
        do {
            let alert = try message.decode(AppWindowCloseBlockedAlertMessage.self)
            onAppWindowCloseBlockedAlert?(alert)
        } catch {
            MirageLogger.error(.client, error: error, message: "Failed to decode app-window close blocked alert: ")
        }
    }

    func handleWindowAddedToStream(_ message: ControlMessage) {
        do {
            let added = try message.decode(WindowAddedToStreamMessage.self)
            MirageLogger.client("Window added to stream: \(added.windowID)")
            storeAppAtlasLayouts(added.atlasLayouts)
            clearPendingStreamSetup(kind: .app)
            onWindowAddedToStream?(added)
        } catch {
            MirageLogger.error(.client, error: error, message: "Failed to decode window added: ")
        }
    }

    func handleWindowRemovedFromStream(_ message: ControlMessage) {
        do {
            let removed = try message.decode(WindowRemovedFromStreamMessage.self)
            MirageLogger.client("Window removed from stream: \(removed.windowID), reason=\(removed.reason.rawValue)")
            onWindowRemovedFromStream?(removed)
        } catch {
            MirageLogger.error(.client, error: error, message: "Failed to decode window removed: ")
        }
    }

    func handleWindowStreamFailed(_ message: ControlMessage) {
        do {
            let failed = try message.decode(WindowStreamFailedMessage.self)
            MirageLogger.client("Window stream failed: \(failed.windowID) reason=\(failed.reason)")
            onWindowStreamFailed?(failed)
        } catch {
            MirageLogger.error(.client, error: error, message: "Failed to decode window stream failed: ")
        }
    }

    func handleAppWindowSwapResult(_ message: ControlMessage) {
        do {
            let result = try message.decode(AppWindowSwapResultMessage.self)
            storeAppAtlasLayouts(result.atlasLayouts)
            if result.success {
                sessionStore.updateSessionAtlasRegion(
                    streamID: result.targetSlotStreamID,
                    atlasRegion: result.atlasRegion
                )
            }
            if result.success {
                MirageLogger.client(
                    "App window swap succeeded: stream=\(result.targetSlotStreamID), window=\(result.windowID)"
                )
            } else {
                MirageLogger.client(
                    "App window swap failed: stream=\(result.targetSlotStreamID), window=\(result.windowID), reason=\(result.reason ?? "unknown")"
                )
            }
            onAppWindowSwapResult?(result)
        } catch {
            MirageLogger.error(.client, error: error, message: "Failed to decode app window swap result: ")
        }
    }

    func handleAppWindowCloseAlertActionResult(_ message: ControlMessage) {
        do {
            let result = try message.decode(AppWindowCloseAlertActionResultMessage.self)
            onAppWindowCloseAlertActionResult?(result)
        } catch {
            MirageLogger.error(.client, error: error, message: "Failed to decode app-window close alert action result: ")
        }
    }

    func handleAppTerminated(_ message: ControlMessage) {
        do {
            let terminated = try message.decode(AppTerminatedMessage.self)
            MirageLogger.client("App terminated: \(terminated.bundleIdentifier)")
            if streamingAppBundleID == terminated.bundleIdentifier {
                streamingAppBundleID = nil
                appWindowInventory = nil
                pendingAppRequestedColorDepth = nil
            }
            onAppTerminated?(terminated)
        } catch {
            MirageLogger.error(.client, error: error, message: "Failed to decode app terminated: ")
        }
    }

    func handleStreamPolicyUpdate(_ message: ControlMessage) {
        do {
            let update = try message.decode(StreamPolicyUpdateMessage.self)
            sessionStore.applyHostStreamPolicies(update.policies)
            Task { [weak self] in
                guard let self else { return }
                await self.applyHostStreamPolicies(update.policies, epoch: update.epoch)
            }
        } catch {
            MirageLogger.error(.client, error: error, message: "Failed to decode stream policy update: ")
        }
    }

    func storeAppAtlasLayouts(_ layouts: [MirageAppAtlasLayout]?) {
        guard let layouts else { return }
        for layout in layouts {
            storeAppAtlasLayout(layout)
        }
    }

    func storeAppAtlasLayout(_ layout: MirageAppAtlasLayout) {
        appAtlasLayoutsByMediaStreamID[layout.mediaStreamID, default: [:]][layout.layoutEpoch] = layout
        sessionStore.updateSessionAtlasRegions(
            mediaStreamID: layout.mediaStreamID,
            layout: layout
        )
    }

    struct AppIconPayload: Sendable {
        let iconData: Data
    }

    private struct PreparedAppListProgress: Sendable {
        let apps: [MirageInstalledApp]
        let rejectedIcons: [RejectedAppIconPayload]
    }

    private struct RejectedAppIconPayload: Sendable {
        let bundleIdentifier: String
        let reason: RejectedAppIconReason
    }

    private enum RejectedAppIconReason: Sendable {
        case invalidImagePayload

        var logDescription: String {
            switch self {
            case .invalidImagePayload:
                "invalid image payload"
            }
        }
    }

    nonisolated private static func appWithUpdatedIconData(
        _ app: MirageInstalledApp,
        iconData: Data?
    ) -> MirageInstalledApp {
        MirageInstalledApp(
            bundleIdentifier: app.bundleIdentifier,
            name: app.name,
            path: app.path,
            iconData: iconData,
            version: app.version,
            isRunning: app.isRunning,
            isBeingStreamed: app.isBeingStreamed
        )
    }

    func rebuildAvailableAppAccumulator(from apps: [MirageInstalledApp]) {
        availableAppsByBundleIdentifier.removeAll(keepingCapacity: true)
        orderedAvailableAppBundleIdentifiers.removeAll(keepingCapacity: true)
        activeAppListReceivedBundleIdentifiers.removeAll(keepingCapacity: true)

        for app in apps {
            let normalizedBundleID = app.bundleIdentifier.lowercased()
            guard !normalizedBundleID.isEmpty else { continue }
            if availableAppsByBundleIdentifier[normalizedBundleID] == nil {
                orderedAvailableAppBundleIdentifiers.append(normalizedBundleID)
            }
            availableAppsByBundleIdentifier[normalizedBundleID] = app
        }
    }

    private func availableIconPayloadsByBundleIdentifierSnapshot() -> [String: AppIconPayload] {
        var iconPayloadsByBundleIdentifier: [String: AppIconPayload] = [:]
        iconPayloadsByBundleIdentifier.reserveCapacity(availableAppsByBundleIdentifier.count)

        for (bundleIdentifier, app) in availableAppsByBundleIdentifier {
            guard let iconData = app.iconData else { continue }
            iconPayloadsByBundleIdentifier[bundleIdentifier] = AppIconPayload(iconData: iconData)
        }
        return iconPayloadsByBundleIdentifier
    }

    nonisolated private static func prepareAppListProgressApps(
        _ apps: [MirageInstalledApp],
        previousIconsByBundleIdentifier: [String: AppIconPayload]
    ) -> PreparedAppListProgress {
        var preparedApps: [MirageInstalledApp] = []
        preparedApps.reserveCapacity(apps.count)
        var rejectedIcons: [RejectedAppIconPayload] = []

        for app in apps {
            let normalizedBundleIdentifier = app.bundleIdentifier.lowercased()

            if let iconData = app.iconData {
                guard isValidImagePayload(iconData) else {
                    rejectedIcons.append(
                        RejectedAppIconPayload(
                            bundleIdentifier: app.bundleIdentifier,
                            reason: .invalidImagePayload
                        )
                    )
                    preparedApps.append(
                        appWithFallbackIconData(
                            app,
                            previousIcon: previousIconsByBundleIdentifier[normalizedBundleIdentifier]
                        )
                    )
                    continue
                }

                preparedApps.append(
                    appWithUpdatedIconData(
                        app,
                        iconData: iconData
                    )
                )
            } else {
                preparedApps.append(
                    appWithFallbackIconData(
                        app,
                        previousIcon: previousIconsByBundleIdentifier[normalizedBundleIdentifier]
                    )
                )
            }
        }

        return PreparedAppListProgress(apps: preparedApps, rejectedIcons: rejectedIcons)
    }

    nonisolated private static func appWithFallbackIconData(
        _ app: MirageInstalledApp,
        previousIcon: AppIconPayload?
    ) -> MirageInstalledApp {
        guard let previousIcon,
              isValidImagePayload(previousIcon.iconData) else {
            return appWithUpdatedIconData(app, iconData: nil)
        }
        return appWithUpdatedIconData(
            app,
            iconData: previousIcon.iconData
        )
    }

    nonisolated private static func isValidImagePayload(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return false
        }
        return CGImageSourceCreateImageAtIndex(source, 0, nil) != nil
    }
}
