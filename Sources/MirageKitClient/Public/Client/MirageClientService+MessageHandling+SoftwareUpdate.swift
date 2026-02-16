//
//  MirageClientService+MessageHandling+SoftwareUpdate.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/16/26.
//
//  Host software update control message handling.
//

import Foundation
import MirageKit

@MainActor
extension MirageClientService {
    func handleHostSoftwareUpdateStatus(_ message: ControlMessage) {
        do {
            let statusMessage = try message.decode(HostSoftwareUpdateStatusMessage.self)
            onHostSoftwareUpdateStatus?(mapHostSoftwareUpdateStatus(statusMessage))
        } catch {
            MirageLogger.error(.client, "Failed to decode host software update status: \(error)")
        }
    }

    func handleHostSoftwareUpdateInstallResult(_ message: ControlMessage) {
        do {
            let installResultMessage = try message.decode(HostSoftwareUpdateInstallResultMessage.self)
            onHostSoftwareUpdateInstallResult?(mapHostSoftwareUpdateInstallResult(installResultMessage))
        } catch {
            MirageLogger.error(.client, "Failed to decode host software update install result: \(error)")
        }
    }

    func mapHostSoftwareUpdateStatus(_ message: HostSoftwareUpdateStatusMessage) -> HostSoftwareUpdateStatus {
        let channel: HostSoftwareUpdateChannel
        switch message.channel {
        case .release:
            channel = .release
        case .nightly:
            channel = .nightly
        }

        return HostSoftwareUpdateStatus(
            isSparkleAvailable: message.isSparkleAvailable,
            isCheckingForUpdates: message.isCheckingForUpdates,
            isInstallInProgress: message.isInstallInProgress,
            channel: channel,
            currentVersion: message.currentVersion,
            availableVersion: message.availableVersion,
            availableVersionTitle: message.availableVersionTitle,
            lastCheckedAtMs: message.lastCheckedAtMs
        )
    }

    func mapHostSoftwareUpdateInstallResult(
        _ message: HostSoftwareUpdateInstallResultMessage
    ) -> HostSoftwareUpdateInstallResult {
        HostSoftwareUpdateInstallResult(
            accepted: message.accepted,
            message: message.message,
            status: message.status.map(mapHostSoftwareUpdateStatus)
        )
    }
}
