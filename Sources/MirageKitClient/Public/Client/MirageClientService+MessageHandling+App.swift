//
//  MirageClientService+MessageHandling+App.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  App-centric streaming message handling.
//

import CryptoKit
import Foundation
import ImageIO
import MirageKit

@MainActor
extension MirageClientService {
    func handleAppListProgress(_ message: ControlMessage) {
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

            let previousIconsByBundleID = availableIconPayloadsByBundleIdentifier(from: availableApps)
            var appByBundleID: [String: MirageInstalledApp] = [:]
            appByBundleID.reserveCapacity(availableApps.count + progress.apps.count)
            for app in availableApps {
                appByBundleID[app.bundleIdentifier.lowercased()] = app
            }

            for app in progress.apps {
                let normalizedBundleID = app.bundleIdentifier.lowercased()
                if app.iconData == nil,
                   let previousIcon = previousIconsByBundleID[normalizedBundleID] {
                    appByBundleID[normalizedBundleID] = appWithUpdatedIconData(
                        app,
                        iconData: previousIcon.iconData,
                        iconSignature: previousIcon.iconSignature
                    )
                } else {
                    appByBundleID[normalizedBundleID] = app
                }
            }

            availableApps = appByBundleID.values.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            onAppListProgress?(availableApps)
        } catch {
            MirageLogger.error(.client, error: error, message: "Failed to decode app-list progress: ")
        }
    }

    func handleAppList(_ message: ControlMessage) {
        guard controlUpdatePolicy != .interactiveStreaming else {
            deferredControlRefreshRequirements.needsAppListRefresh = true
            return
        }
        do {
            let appList = try message.decode(AppListMessage.self)
            MirageLogger.client("Received app list with \(appList.apps.count) apps requestID=\(appList.requestID.uuidString)")

            let previousIconsByBundleID = availableIconPayloadsByBundleIdentifier(from: availableApps)
            availableApps = appList.apps.map { app in
                guard app.iconData == nil,
                      let previousIcon = previousIconsByBundleID[app.bundleIdentifier.lowercased()]
                else {
                    return app
                }
                return appWithUpdatedIconData(
                    app,
                    iconData: previousIcon.iconData,
                    iconSignature: previousIcon.iconSignature
                )
            }
            hasReceivedAppList = true
            appIconStreamStateByRequestID.removeAll(keepingCapacity: false)
            activeAppListRequestID = appList.requestID
            appIconStreamStateByRequestID[appList.requestID] = AppIconStreamState()
            onAppListReceived?(availableApps)
        } catch {
            MirageLogger.error(.client, error: error, message: "Failed to decode app list: ")
        }
    }

    func handleAppIconUpdate(_ message: ControlMessage) {
        guard controlUpdatePolicy != .interactiveStreaming else {
            deferredControlRefreshRequirements.needsAppListRefresh = true
            return
        }
        do {
            let update = try message.decode(AppIconUpdateMessage.self)
            guard activeAppListRequestID == update.requestID else {
                MirageLogger.client(
                    "Ignoring app icon update for stale requestID=\(update.requestID.uuidString)"
                )
                return
            }

            let computedSignature = Self.sha256Hex(update.iconData)
            guard computedSignature == update.iconSignature else {
                pendingForceIconResetForNextAppListRequest = true
                MirageLogger.client(
                    "Rejected app icon update due to signature mismatch for bundleID=\(update.bundleIdentifier)"
                )
                return
            }

            let normalizedBundleID = update.bundleIdentifier.lowercased()
            guard let appIndex = availableApps.firstIndex(where: {
                $0.bundleIdentifier.lowercased() == normalizedBundleID
            }) else {
                MirageLogger.client(
                    "Ignoring app icon update for unknown bundleID=\(update.bundleIdentifier)"
                )
                return
            }

            let updatedApp = appWithUpdatedIconData(
                availableApps[appIndex],
                iconData: update.iconData,
                iconSignature: update.iconSignature
            )
            availableApps[appIndex] = updatedApp
            appIconStreamStateByRequestID[update.requestID, default: AppIconStreamState()]
                .receivedBundleIdentifiers
                .insert(normalizedBundleID)
            onAppIconStreamProgress?(availableApps)
        } catch {
            MirageLogger.error(.client, error: error, message: "Failed to decode app icon update: ")
        }
    }

    func handleAppIconStreamComplete(_ message: ControlMessage) {
        guard controlUpdatePolicy != .interactiveStreaming else {
            deferredControlRefreshRequirements.needsAppListRefresh = true
            return
        }
        do {
            let complete = try message.decode(AppIconStreamCompleteMessage.self)
            guard activeAppListRequestID == complete.requestID else {
                MirageLogger.client(
                    "Ignoring app icon completion for stale requestID=\(complete.requestID.uuidString)"
                )
                return
            }

            var streamState = appIconStreamStateByRequestID[complete.requestID] ?? AppIconStreamState()
            streamState.skippedBundleIdentifiers = Set(
                complete.skippedBundleIdentifiers.map { $0.lowercased() }
            )
            appIconStreamStateByRequestID[complete.requestID] = streamState

            let requiresForceReset = streamState.skippedBundleIdentifiers.contains { skippedBundleIdentifier in
                guard let app = availableApps.first(where: {
                    $0.bundleIdentifier.lowercased() == skippedBundleIdentifier
                }) else {
                    return false
                }
                guard let iconData = app.iconData else {
                    return true
                }
                return !Self.isValidImagePayload(iconData)
            }

            if requiresForceReset {
                pendingForceIconResetForNextAppListRequest = true
                MirageLogger.client(
                    "Queued force icon reset for next app-list request (desync detected for requestID=\(complete.requestID.uuidString))"
                )
            }

            MirageLogger.client(
                "App icon stream complete requestID=\(complete.requestID.uuidString) sent=\(complete.sentIconCount) skipped=\(complete.skippedBundleIdentifiers.count)"
            )

            // Publish one consolidated update after icon streaming completes instead of
            // emitting one full app-list callback per icon packet.
            onAppListReceived?(availableApps)
            appIconStreamStateByRequestID.removeValue(forKey: complete.requestID)
        } catch {
            MirageLogger.error(.client, error: error, message: "Failed to decode app icon stream completion: ")
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
            onAppStreamStarted?(started)
        } catch {
            MirageLogger.error(.client, error: error, message: "Failed to decode app stream started: ")
        }
    }

    func handleAppWindowInventory(_ message: ControlMessage) {
        do {
            let inventory = try message.decode(AppWindowInventoryMessage.self)
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

    private struct AppIconPayload {
        let iconData: Data
        let iconSignature: String
    }

    private func appWithUpdatedIconData(
        _ app: MirageInstalledApp,
        iconData: Data?,
        iconSignature: String?
    ) -> MirageInstalledApp {
        MirageInstalledApp(
            bundleIdentifier: app.bundleIdentifier,
            name: app.name,
            path: app.path,
            iconData: iconData,
            iconSignature: iconSignature,
            version: app.version,
            isRunning: app.isRunning,
            isBeingStreamed: app.isBeingStreamed
        )
    }

    private func availableIconPayloadsByBundleIdentifier(from apps: [MirageInstalledApp]) -> [String: AppIconPayload] {
        var iconsByBundleIdentifier: [String: AppIconPayload] = [:]
        iconsByBundleIdentifier.reserveCapacity(apps.count)
        for app in apps {
            guard let iconData = app.iconData else { continue }
            let iconSignature = app.iconSignature ?? Self.sha256Hex(iconData)
            iconsByBundleIdentifier[app.bundleIdentifier.lowercased()] = AppIconPayload(
                iconData: iconData,
                iconSignature: iconSignature
            )
        }
        return iconsByBundleIdentifier
    }

    private static func isValidImagePayload(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return false
        }
        return CGImageSourceCreateImageAtIndex(source, 0, nil) != nil
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
