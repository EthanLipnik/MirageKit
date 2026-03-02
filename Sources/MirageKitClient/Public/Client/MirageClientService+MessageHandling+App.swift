//
//  MirageClientService+MessageHandling+App.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  App-centric streaming message handling.
//

import Foundation
import MirageKit

@MainActor
extension MirageClientService {
    func handleAppList(_ message: ControlMessage) {
        do {
            let appList = try message.decode(AppListMessage.self)
            MirageLogger.client("Received app list with \(appList.apps.count) apps")
            availableApps = appList.apps
            hasReceivedAppList = true
            onAppListReceived?(appList.apps)
        } catch {
            MirageLogger.error(.client, error: error, message: "Failed to decode app list: ")
        }
    }

    func handleHostHardwareIcon(_ message: ControlMessage) {
        do {
            let hostIcon = try message.decode(HostHardwareIconMessage.self)
            guard let hostID = connectedHost?.id else {
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

    func handleAppStreamStarted(_ message: ControlMessage) {
        do {
            let started = try message.decode(AppStreamStartedMessage.self)
            MirageLogger.client("App stream started: \(started.appName) with \(started.windows.count) windows")
            streamingAppBundleID = started.bundleIdentifier
            appWindowInventory = nil
            onAppStreamStarted?(started.bundleIdentifier, started.appName, started.windows)
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
                pendingAppAdaptiveFallbackBitrate = nil
                pendingAppAdaptiveFallbackBitDepth = nil
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
}
