//
//  MirageHostService+SoftwareUpdate.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/16/26.
//
//  Host software update request handling.
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
import Loom

#if os(macOS)
@MainActor
extension MirageHostService {
    /// Handles a client request for the latest host software-update status.
    func handleHostSoftwareUpdateStatusRequest(
        _ message: MirageWire.ControlMessage,
        from clientContext: ClientContext
    ) async {
        let request: MirageWire.HostSoftwareUpdateStatusRequestMessage
        do {
            request = try message.decode(MirageWire.HostSoftwareUpdateStatusRequestMessage.self)
        } catch {
            MirageLogger.error(.host, error: error, message: "Failed to decode host software update status request: ")
            return
        }

        if var pending = pendingHostSoftwareUpdateStatusRequest,
           pending.clientID == clientContext.client.id {
            pending.forceRefresh = pending.forceRefresh || request.forceRefresh
            pendingHostSoftwareUpdateStatusRequest = pending
        } else {
            pendingHostSoftwareUpdateStatusRequest = PendingHostSoftwareUpdateStatusRequest(
                clientID: clientContext.client.id,
                forceRefresh: request.forceRefresh
            )
        }

        sendPendingHostSoftwareUpdateStatusRequestIfPossible()
    }

    /// Sends pending software-update status when interactive work is idle.
    func sendPendingHostSoftwareUpdateStatusRequestIfPossible() {
        guard let pending = pendingHostSoftwareUpdateStatusRequest else { return }
        guard !isInteractiveWorkloadActiveForAppListRequests else {
            MirageLogger.host("Deferring host software update status while interactive workload is active")
            return
        }
        guard let clientContext = findClientContext(clientID: pending.clientID) else {
            pendingHostSoftwareUpdateStatusRequest = nil
            return
        }

        hostSoftwareUpdateStatusRequestTask?.cancel()
        let token = UUID()
        let clientID = pending.clientID
        let forceRefresh = pending.forceRefresh
        hostSoftwareUpdateStatusRequestToken = token
        hostSoftwareUpdateStatusRequestTask = Task { @MainActor [weak self] in
            guard let self else { return }

            let status = await resolveHostSoftwareUpdateStatus(
                forceRefresh: forceRefresh
            )
            guard !Task.isCancelled else { return }

            do {
                try await clientContext.send(.hostSoftwareUpdateStatus, content: status)
                MirageLogger.host("Sent host software update status to \(clientContext.client.name)")
            } catch {
                await handleControlChannelSendFailure(
                    client: clientContext.client,
                    error: error,
                    operation: "Host software update status",
                    sessionID: clientContext.sessionID
                )
                return
            }
            guard !Task.isCancelled else { return }

            if hostSoftwareUpdateStatusRequestToken == token,
               pendingHostSoftwareUpdateStatusRequest?.clientID == clientID {
                pendingHostSoftwareUpdateStatusRequest = nil
                hostSoftwareUpdateStatusRequestTask = nil
            }
        }
    }

    /// Handles a client request to start a host software-update install.
    func handleHostSoftwareUpdateInstallRequest(
        from clientContext: ClientContext
    ) async {
        do {
            let peer = peerIdentityByClientID[clientContext.client.id]
            let result = await resolveHostSoftwareUpdateInstallResult(for: peer)
            try await clientContext.send(.hostSoftwareUpdateInstallResult, content: result)
            MirageLogger.host(
                "Handled host software update install request from \(clientContext.client.name): " +
                    "resultCode=\(result.resultCode.rawValue), " +
                    "blockReason=\(result.blockReason?.rawValue ?? "nil"), message=\(result.message)"
            )
        } catch {
            await handleControlChannelSendFailure(
                client: clientContext.client,
                error: error,
                operation: "Host software update install",
                sessionID: clientContext.sessionID
            )
        }
    }

    /// Sends the latest host software update status to all currently connected clients.
    ///
    /// Delivery is best-effort: clients with disconnected or unwritable control channels are skipped.
    public func broadcastHostSoftwareUpdateStatus(
        _ snapshot: MirageHostSoftwareUpdateStatusSnapshot
    ) {
        guard !clientsBySessionID.isEmpty else { return }

        let message = MirageWire.HostSoftwareUpdateStatusMessage(snapshot: snapshot)
        for clientContext in clientsBySessionID.values {
            guard clientContext.sendBestEffort(.hostSoftwareUpdateStatus, content: message) else {
                MirageLogger.host("Failed to encode host software update status for \(clientContext.client.name)")
                continue
            }
        }
    }

    /// Resolves the current software-update status payload.
    func resolveHostSoftwareUpdateStatus(forceRefresh: Bool) async -> MirageWire.HostSoftwareUpdateStatusMessage {
        guard let softwareUpdateController else {
            return fallbackHostSoftwareUpdateStatusMessage()
        }
        let snapshot = await softwareUpdateController.softwareUpdateStatus(
            forceRefresh: forceRefresh
        )
        return MirageWire.HostSoftwareUpdateStatusMessage(snapshot: snapshot)
    }

    /// Resolves the install result payload for a client-initiated update request.
    func resolveHostSoftwareUpdateInstallResult(
        for peer: LoomPeerIdentity?
    ) async -> MirageWire.HostSoftwareUpdateInstallResultMessage {
        guard let softwareUpdateController else {
            return fallbackHostSoftwareUpdateInstallResultMessage(
                message: "Host update service unavailable.",
                resultCode: .unavailable,
                blockReason: .serviceUnavailable
            )
        }

        guard let peer else {
            return fallbackHostSoftwareUpdateInstallResultMessage(
                message: "Missing peer identity metadata.",
                resultCode: .denied,
                blockReason: .policyDenied
            )
        }

        let result: MirageHostSoftwareUpdateInstallResult
        if let identityController = softwareUpdateController as? any MirageHostSoftwareUpdateIdentityController {
            result = await identityController.performSoftwareUpdateInstall(
                for: MirageAuthenticatedPeerIdentity(loomPeerIdentity: peer)
            )
        } else {
            result = await softwareUpdateController.performSoftwareUpdateInstall(for: peer)
        }
        return MirageWire.HostSoftwareUpdateInstallResultMessage(result: result)
    }
}

private extension MirageHostService {
    /// Builds a software-update install-result payload when installation cannot reach the updater.
    func fallbackHostSoftwareUpdateInstallResultMessage(
        message: String,
        resultCode: MirageWire.HostSoftwareUpdateInstallResultCode,
        blockReason: MirageWire.HostSoftwareUpdateBlockReason
    ) -> MirageWire.HostSoftwareUpdateInstallResultMessage {
        MirageWire.HostSoftwareUpdateInstallResultMessage(
            message: message,
            resultCode: resultCode,
            blockReason: blockReason,
            remediationHint: nil,
            status: fallbackHostSoftwareUpdateStatusMessage()
        )
    }

    /// Builds a software-update status payload for hosts without an update controller.
    func fallbackHostSoftwareUpdateStatusMessage() -> MirageWire.HostSoftwareUpdateStatusMessage {
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return MirageWire.HostSoftwareUpdateStatusMessage(
            isSparkleAvailable: false,
            isCheckingForUpdates: false,
            isInstallInProgress: false,
            channel: .release,
            automationMode: .metadataOnly,
            installDisposition: .idle,
            lastBlockReason: nil,
            lastInstallResultCode: .unavailable,
            canCancelUpdate: false,
            downloadExpectedBytes: nil,
            downloadReceivedBytes: 0,
            extractionProgress: nil,
            lastErrorSummary: nil,
            lastErrorDetails: nil,
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

private extension MirageWire.HostSoftwareUpdateStatusMessage {
    /// Converts a host updater snapshot into the software-update status wire payload.
    init(snapshot: MirageHostSoftwareUpdateStatusSnapshot) {
        self.init(
            isSparkleAvailable: snapshot.isSparkleAvailable,
            isCheckingForUpdates: snapshot.isCheckingForUpdates,
            isInstallInProgress: snapshot.isInstallInProgress,
            channel: mirageMappedEnum(snapshot.channel),
            automationMode: mirageMappedEnum(snapshot.automationMode),
            installDisposition: mirageMappedEnum(snapshot.installDisposition),
            lastBlockReason: snapshot.lastBlockReason.map { mirageMappedEnum($0) },
            lastInstallResultCode: snapshot.lastInstallResultCode.map { mirageMappedEnum($0) },
            canCancelUpdate: snapshot.canCancelUpdate,
            downloadExpectedBytes: snapshot.downloadExpectedBytes,
            downloadReceivedBytes: snapshot.downloadReceivedBytes,
            extractionProgress: snapshot.extractionProgress,
            lastErrorSummary: snapshot.lastErrorSummary,
            lastErrorDetails: snapshot.lastErrorDetails,
            currentVersion: snapshot.currentVersion,
            availableVersion: snapshot.availableVersion,
            availableVersionTitle: snapshot.availableVersionTitle,
            releaseNotesSummary: snapshot.releaseNotesSummary,
            releaseNotesBody: snapshot.releaseNotesBody,
            releaseNotesFormat: snapshot.releaseNotesFormat.map { mirageMappedEnum($0) },
            lastCheckedAtMs: snapshot.lastCheckedAtMs
        )
    }
}

private extension MirageWire.HostSoftwareUpdateInstallResultMessage {
    /// Converts a host updater install result into the install-result wire payload.
    init(result: MirageHostSoftwareUpdateInstallResult) {
        self.init(
            message: result.message,
            resultCode: mirageMappedEnum(result.code),
            blockReason: result.blockReason.map { mirageMappedEnum($0) },
            remediationHint: result.remediationHint,
            status: MirageWire.HostSoftwareUpdateStatusMessage(snapshot: result.status)
        )
    }
}
#endif
