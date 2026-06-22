//
//  MirageClientService+AppListMessages.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/13/26.
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

@MainActor
extension MirageClientService {
    /// Merges an app-list progress page into the ordered app accumulator.
    func handleAppListProgress(_ message: MirageWire.ControlMessage) async {
        guard controlUpdatePolicy != .interactiveStreaming else {
            deferredControlRefreshRequirements.needsAppListRefresh = true
            return
        }
        do {
            let progress = try message.decode(MirageWire.AppListProgressMessage.self)
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

    /// Finalizes an app-list request and publishes the completed ordered app list.
    func handleAppListComplete(_ message: MirageWire.ControlMessage) {
        guard controlUpdatePolicy != .interactiveStreaming else {
            deferredControlRefreshRequirements.needsAppListRefresh = true
            return
        }
        do {
            let complete = try message.decode(MirageWire.AppListCompleteMessage.self)
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
}
