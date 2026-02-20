//
//  MirageHostService+SoftwareUpdate.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/16/26.
//
//  Host software update request handling.
//

import Foundation
import MirageKit

#if os(macOS)
import Network

@MainActor
extension MirageHostService {
    func handleHostSoftwareUpdateStatusRequest(
        _ message: ControlMessage,
        from client: MirageConnectedClient,
        connection: NWConnection
    ) async {
        guard let clientContext = clientsByConnection[ObjectIdentifier(connection)] else {
            MirageLogger.host("Ignoring host software update status request from unknown connection")
            return
        }

        do {
            let request = try message.decode(HostSoftwareUpdateStatusRequestMessage.self)
            let peer = peerIdentityByClientID[client.id]
            let status = await resolveHostSoftwareUpdateStatus(for: peer, forceRefresh: request.forceRefresh)

            try await clientContext.send(.hostSoftwareUpdateStatus, content: status)
            MirageLogger.host("Sent host software update status to \(client.name)")
        } catch {
            MirageLogger.error(.host, "Failed to handle host software update status request: \(error)")
        }
    }

    func handleHostSoftwareUpdateInstallRequest(
        _ message: ControlMessage,
        from client: MirageConnectedClient,
        connection: NWConnection
    ) async {
        guard let clientContext = clientsByConnection[ObjectIdentifier(connection)] else {
            MirageLogger.host("Ignoring host software update install request from unknown connection")
            return
        }

        do {
            let request = try message.decode(HostSoftwareUpdateInstallRequestMessage.self)
            let peer = peerIdentityByClientID[client.id]
            let result = await resolveHostSoftwareUpdateInstallResult(for: peer, trigger: request.trigger)
            try await clientContext.send(.hostSoftwareUpdateInstallResult, content: result)
            MirageLogger.host(
                "Handled host software update install request from \(client.name): accepted=\(result.accepted)"
            )
        } catch {
            MirageLogger.error(.host, "Failed to handle host software update install request: \(error)")
        }
    }

    func resolveHostSoftwareUpdateStatus(
        for peer: MiragePeerIdentity?,
        forceRefresh: Bool
    ) async -> HostSoftwareUpdateStatusMessage {
        guard let softwareUpdateController,
              let peer else {
            return fallbackHostSoftwareUpdateStatusMessage()
        }
        let snapshot = await softwareUpdateController.hostService(
            self,
            softwareUpdateStatusFor: peer,
            forceRefresh: forceRefresh
        )
        return makeHostSoftwareUpdateStatusMessage(from: snapshot)
    }

    func resolveHostSoftwareUpdateInstallResult(
        for peer: MiragePeerIdentity?,
        trigger: HostSoftwareUpdateInstallRequestMessage.Trigger
    ) async -> HostSoftwareUpdateInstallResultMessage {
        guard let softwareUpdateController else {
            let fallbackStatus = fallbackHostSoftwareUpdateStatusMessage()
            return HostSoftwareUpdateInstallResultMessage(
                accepted: false,
                message: "Host update service unavailable.",
                resultCode: .unavailable,
                blockReason: .serviceUnavailable,
                remediationHint: nil,
                status: fallbackStatus
            )
        }

        guard let peer else {
            let fallbackStatus = fallbackHostSoftwareUpdateStatusMessage()
            return HostSoftwareUpdateInstallResultMessage(
                accepted: false,
                message: "Missing peer identity metadata.",
                resultCode: .denied,
                blockReason: .policyDenied,
                remediationHint: nil,
                status: fallbackStatus
            )
        }

        let resolvedTrigger = mapHostSoftwareUpdateInstallTrigger(trigger)
        let authorized = await softwareUpdateController.hostService(
            self,
            shouldAuthorizeSoftwareUpdateRequestFrom: peer,
            trigger: resolvedTrigger
        )
        guard authorized else {
            let snapshot = await softwareUpdateController.hostService(
                self,
                softwareUpdateStatusFor: peer,
                forceRefresh: false
            )
            return HostSoftwareUpdateInstallResultMessage(
                accepted: false,
                message: "Remote update request denied for this device.",
                resultCode: .denied,
                blockReason: .policyDenied,
                remediationHint: nil,
                status: makeHostSoftwareUpdateStatusMessage(from: snapshot)
            )
        }

        let result = await softwareUpdateController.hostService(
            self,
            performSoftwareUpdateInstallFor: peer,
            trigger: resolvedTrigger
        )
        return makeHostSoftwareUpdateInstallResultMessage(from: result)
    }
}

private extension MirageHostService {
    func mapHostSoftwareUpdateInstallTrigger(
        _ trigger: HostSoftwareUpdateInstallRequestMessage.Trigger
    ) -> MirageHostSoftwareUpdateInstallTrigger {
        switch trigger {
        case .protocolMismatch:
            return .protocolMismatch
        case .manual:
            return .manual
        }
    }

    func makeHostSoftwareUpdateStatusMessage(
        from snapshot: MirageHostSoftwareUpdateStatusSnapshot
    ) -> HostSoftwareUpdateStatusMessage {
        let channel: HostSoftwareUpdateChannel
        switch snapshot.channel {
        case .release:
            channel = .release
        case .nightly:
            channel = .nightly
        }

        let automationMode: HostSoftwareUpdateAutomationMode
        switch snapshot.automationMode {
        case .metadataOnly:
            automationMode = .metadataOnly
        case .autoDownload:
            automationMode = .autoDownload
        case .autoInstall:
            automationMode = .autoInstall
        }

        let installDisposition: HostSoftwareUpdateInstallDisposition
        switch snapshot.installDisposition {
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
        switch snapshot.lastBlockReason {
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
        switch snapshot.lastInstallResultCode {
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
        switch snapshot.releaseNotesFormat {
        case .none:
            releaseNotesFormat = nil
        case .plainText:
            releaseNotesFormat = .plainText
        case .html:
            releaseNotesFormat = .html
        }

        return HostSoftwareUpdateStatusMessage(
            isSparkleAvailable: snapshot.isSparkleAvailable,
            isCheckingForUpdates: snapshot.isCheckingForUpdates,
            isInstallInProgress: snapshot.isInstallInProgress,
            channel: channel,
            automationMode: automationMode,
            installDisposition: installDisposition,
            lastBlockReason: lastBlockReason,
            lastInstallResultCode: lastInstallResultCode,
            currentVersion: snapshot.currentVersion,
            availableVersion: snapshot.availableVersion,
            availableVersionTitle: snapshot.availableVersionTitle,
            releaseNotesSummary: snapshot.releaseNotesSummary,
            releaseNotesBody: snapshot.releaseNotesBody,
            releaseNotesFormat: releaseNotesFormat,
            lastCheckedAtMs: snapshot.lastCheckedAtMs
        )
    }

    func makeHostSoftwareUpdateInstallResultMessage(
        from result: MirageHostSoftwareUpdateInstallResult
    ) -> HostSoftwareUpdateInstallResultMessage {
        let resultCode: HostSoftwareUpdateInstallResultCode
        switch result.code {
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
        switch result.blockReason {
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

        return HostSoftwareUpdateInstallResultMessage(
            accepted: result.accepted,
            message: result.message,
            resultCode: resultCode,
            blockReason: blockReason,
            remediationHint: result.remediationHint,
            status: makeHostSoftwareUpdateStatusMessage(from: result.status)
        )
    }

    func fallbackHostSoftwareUpdateStatusMessage() -> HostSoftwareUpdateStatusMessage {
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return HostSoftwareUpdateStatusMessage(
            isSparkleAvailable: false,
            isCheckingForUpdates: false,
            isInstallInProgress: false,
            channel: .release,
            automationMode: .metadataOnly,
            installDisposition: .idle,
            lastBlockReason: nil,
            lastInstallResultCode: .unavailable,
            currentVersion: appVersion ?? MirageKit.version,
            availableVersion: nil,
            availableVersionTitle: nil,
            releaseNotesSummary: nil,
            releaseNotesBody: nil,
            releaseNotesFormat: nil,
            lastCheckedAtMs: nil
        )
    }
}
#endif
