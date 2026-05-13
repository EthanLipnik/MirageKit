//
//  MirageClientService+MessageHandling+SoftwareUpdate.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/16/26.
//
//  Host software update control message handling.
//

import MirageKit

@MainActor
extension MirageClientService {
    func handleHostSoftwareUpdateStatus(_ message: ControlMessage) {
        guard controlUpdatePolicy != .interactiveStreaming else {
            deferredControlRefreshRequirements.needsHostSoftwareUpdateRefresh = true
            return
        }
        do {
            let statusMessage = try message.decode(HostSoftwareUpdateStatusMessage.self)
            onHostSoftwareUpdateStatus?(HostSoftwareUpdateStatus(message: statusMessage))
        } catch {
            MirageLogger.error(.client, error: error, message: "Failed to decode host software update status: ")
        }
    }

    func handleHostSoftwareUpdateInstallResult(_ message: ControlMessage) {
        do {
            let installResultMessage = try message.decode(HostSoftwareUpdateInstallResultMessage.self)
            onHostSoftwareUpdateInstallResult?(HostSoftwareUpdateInstallResult(message: installResultMessage))
        } catch {
            MirageLogger.error(.client, error: error, message: "Failed to decode host software update install result: ")
        }
    }
}

private extension MirageClientService.HostSoftwareUpdateStatus {
    /// Converts the host wire payload into the client-facing software-update model.
    init(message: HostSoftwareUpdateStatusMessage) {
        self.init(
            isSparkleAvailable: message.isSparkleAvailable,
            isCheckingForUpdates: message.isCheckingForUpdates,
            isInstallInProgress: message.isInstallInProgress,
            channel: mirageMappedEnum(message.channel),
            automationMode: mirageMappedEnum(message.automationMode),
            installDisposition: mirageMappedEnum(message.installDisposition),
            lastBlockReason: message.lastBlockReason.map { mirageMappedEnum($0) },
            lastInstallResultCode: message.lastInstallResultCode.map { mirageMappedEnum($0) },
            canCancelUpdate: message.canCancelUpdate,
            downloadExpectedBytes: message.downloadExpectedBytes,
            downloadReceivedBytes: message.downloadReceivedBytes,
            extractionProgress: message.extractionProgress,
            lastErrorSummary: message.lastErrorSummary,
            lastErrorDetails: message.lastErrorDetails,
            currentVersion: message.currentVersion,
            availableVersion: message.availableVersion,
            availableVersionTitle: message.availableVersionTitle,
            releaseNotesSummary: message.releaseNotesSummary,
            releaseNotesBody: message.releaseNotesBody,
            releaseNotesFormat: message.releaseNotesFormat.map { mirageMappedEnum($0) },
            lastCheckedAtMs: message.lastCheckedAtMs
        )
    }
}

private extension MirageClientService.HostSoftwareUpdateInstallResult {
    /// Converts a host install-result wire payload into the client-facing result model.
    init(message: HostSoftwareUpdateInstallResultMessage) {
        self.init(
            accepted: message.resultCode == .started,
            message: message.message,
            resultCode: mirageMappedEnum(message.resultCode),
            blockReason: message.blockReason.map { mirageMappedEnum($0) },
            remediationHint: message.remediationHint,
            status: MirageClientService.HostSoftwareUpdateStatus(message: message.status)
        )
    }
}
