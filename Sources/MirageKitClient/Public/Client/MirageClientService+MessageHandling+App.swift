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
            MirageLogger.error(.client, "Failed to decode app list: \(error)")
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
            MirageLogger.error(.client, "Failed to decode host hardware icon: \(error)")
        }
    }

    func handleAppStreamStarted(_ message: ControlMessage) {
        do {
            let started = try message.decode(AppStreamStartedMessage.self)
            MirageLogger.client("App stream started: \(started.appName) with \(started.windows.count) windows")
            streamingAppBundleID = started.bundleIdentifier
            onAppStreamStarted?(started.bundleIdentifier, started.appName, started.windows)
        } catch {
            MirageLogger.error(.client, "Failed to decode app stream started: \(error)")
        }
    }

    func handleWindowAddedToStream(_ message: ControlMessage) {
        do {
            let added = try message.decode(WindowAddedToStreamMessage.self)
            MirageLogger.client("Window added to stream: \(added.windowID)")
            onWindowAddedToStream?(added)
        } catch {
            MirageLogger.error(.client, "Failed to decode window added: \(error)")
        }
    }

    func handleWindowCooldownStarted(_ message: ControlMessage) {
        do {
            let cooldown = try message.decode(WindowCooldownStartedMessage.self)
            MirageLogger.client("Window cooldown started: \(cooldown.windowID) for \(cooldown.durationSeconds)s")
            onWindowCooldownStarted?(cooldown)
        } catch {
            MirageLogger.error(.client, "Failed to decode cooldown started: \(error)")
        }
    }

    func handleWindowCooldownCancelled(_ message: ControlMessage) {
        do {
            let cancelled = try message.decode(WindowCooldownCancelledMessage.self)
            MirageLogger.client("Window cooldown cancelled, new window: \(cancelled.newWindowID)")
            onWindowCooldownCancelled?(cancelled)
        } catch {
            MirageLogger.error(.client, "Failed to decode cooldown cancelled: \(error)")
        }
    }

    func handleReturnToAppSelection(_ message: ControlMessage) {
        do {
            let returnMsg = try message.decode(ReturnToAppSelectionMessage.self)
            MirageLogger.client("Return to app selection for window: \(returnMsg.windowID)")
            streamingAppBundleID = nil
            pendingAppAdaptiveFallbackBitrate = nil
            pendingAppAdaptiveFallbackBitDepth = nil
            onReturnToAppSelection?(returnMsg)
        } catch {
            MirageLogger.error(.client, "Failed to decode return to app selection: \(error)")
        }
    }

    func handleAppTerminated(_ message: ControlMessage) {
        do {
            let terminated = try message.decode(AppTerminatedMessage.self)
            MirageLogger.client("App terminated: \(terminated.bundleIdentifier)")
            if streamingAppBundleID == terminated.bundleIdentifier {
                streamingAppBundleID = nil
                pendingAppAdaptiveFallbackBitrate = nil
                pendingAppAdaptiveFallbackBitDepth = nil
            }
            onAppTerminated?(terminated)
        } catch {
            MirageLogger.error(.client, "Failed to decode app terminated: \(error)")
        }
    }
}
