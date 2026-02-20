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

        let automationMode: HostSoftwareUpdateAutomationMode?
        switch message.automationMode {
        case .none:
            automationMode = nil
        case .metadataOnly:
            automationMode = .metadataOnly
        case .autoDownload:
            automationMode = .autoDownload
        case .autoInstall:
            automationMode = .autoInstall
        }

        let installDisposition: HostSoftwareUpdateInstallDisposition?
        switch message.installDisposition {
        case .none:
            installDisposition = nil
        case .idle:
            installDisposition = .idle
        case .checking:
            installDisposition = .checking
        case .updateAvailable:
            installDisposition = .updateAvailable
        case .downloading:
            installDisposition = .downloading
        case .installing:
            installDisposition = .installing
        case .completed:
            installDisposition = .completed
        case .blocked:
            installDisposition = .blocked
        case .failed:
            installDisposition = .failed
        }

        let lastBlockReason: HostSoftwareUpdateBlockReason?
        switch message.lastBlockReason {
        case .none:
            lastBlockReason = nil
        case .clientUpdatesDisabled:
            lastBlockReason = .clientUpdatesDisabled
        case .hostUpdaterBusy:
            lastBlockReason = .hostUpdaterBusy
        case .unattendedInstallUnsupported:
            lastBlockReason = .unattendedInstallUnsupported
        case .insufficientPermissions:
            lastBlockReason = .insufficientPermissions
        case .authorizationRequired:
            lastBlockReason = .authorizationRequired
        case .serviceUnavailable:
            lastBlockReason = .serviceUnavailable
        case .policyDenied:
            lastBlockReason = .policyDenied
        case .unknown:
            lastBlockReason = .unknown
        }

        let lastInstallResultCode: HostSoftwareUpdateInstallResultCode?
        switch message.lastInstallResultCode {
        case .none:
            lastInstallResultCode = nil
        case .started:
            lastInstallResultCode = .started
        case .alreadyInProgress:
            lastInstallResultCode = .alreadyInProgress
        case .noUpdateAvailable:
            lastInstallResultCode = .noUpdateAvailable
        case .denied:
            lastInstallResultCode = .denied
        case .blocked:
            lastInstallResultCode = .blocked
        case .failed:
            lastInstallResultCode = .failed
        case .unavailable:
            lastInstallResultCode = .unavailable
        }

        let releaseNotesFormat: HostSoftwareUpdateReleaseNotesFormat?
        switch message.releaseNotesFormat {
        case .none:
            releaseNotesFormat = nil
        case .plainText:
            releaseNotesFormat = .plainText
        case .html:
            releaseNotesFormat = .html
        }

        return HostSoftwareUpdateStatus(
            isSparkleAvailable: message.isSparkleAvailable,
            isCheckingForUpdates: message.isCheckingForUpdates,
            isInstallInProgress: message.isInstallInProgress,
            channel: channel,
            automationMode: automationMode,
            installDisposition: installDisposition,
            lastBlockReason: lastBlockReason,
            lastInstallResultCode: lastInstallResultCode,
            currentVersion: message.currentVersion,
            availableVersion: message.availableVersion,
            availableVersionTitle: message.availableVersionTitle,
            releaseNotesSummary: message.releaseNotesSummary,
            releaseNotesBody: message.releaseNotesBody,
            releaseNotesFormat: releaseNotesFormat,
            lastCheckedAtMs: message.lastCheckedAtMs
        )
    }

    func mapHostSoftwareUpdateInstallResult(
        _ message: HostSoftwareUpdateInstallResultMessage
    ) -> HostSoftwareUpdateInstallResult {
        let resultCode: HostSoftwareUpdateInstallResultCode?
        switch message.resultCode {
        case .none:
            resultCode = nil
        case .started:
            resultCode = .started
        case .alreadyInProgress:
            resultCode = .alreadyInProgress
        case .noUpdateAvailable:
            resultCode = .noUpdateAvailable
        case .denied:
            resultCode = .denied
        case .blocked:
            resultCode = .blocked
        case .failed:
            resultCode = .failed
        case .unavailable:
            resultCode = .unavailable
        }

        let blockReason: HostSoftwareUpdateBlockReason?
        switch message.blockReason {
        case .none:
            blockReason = nil
        case .clientUpdatesDisabled:
            blockReason = .clientUpdatesDisabled
        case .hostUpdaterBusy:
            blockReason = .hostUpdaterBusy
        case .unattendedInstallUnsupported:
            blockReason = .unattendedInstallUnsupported
        case .insufficientPermissions:
            blockReason = .insufficientPermissions
        case .authorizationRequired:
            blockReason = .authorizationRequired
        case .serviceUnavailable:
            blockReason = .serviceUnavailable
        case .policyDenied:
            blockReason = .policyDenied
        case .unknown:
            blockReason = .unknown
        }

        return HostSoftwareUpdateInstallResult(
            accepted: message.accepted,
            message: message.message,
            resultCode: resultCode,
            blockReason: blockReason,
            remediationHint: message.remediationHint,
            status: message.status.map(mapHostSoftwareUpdateStatus)
        )
    }
}
