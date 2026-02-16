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
                status: fallbackStatus
            )
        }

        guard let peer else {
            let fallbackStatus = fallbackHostSoftwareUpdateStatusMessage()
            return HostSoftwareUpdateInstallResultMessage(
                accepted: false,
                message: "Missing peer identity metadata.",
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

        return HostSoftwareUpdateStatusMessage(
            isSparkleAvailable: snapshot.isSparkleAvailable,
            isCheckingForUpdates: snapshot.isCheckingForUpdates,
            isInstallInProgress: snapshot.isInstallInProgress,
            channel: channel,
            currentVersion: snapshot.currentVersion,
            availableVersion: snapshot.availableVersion,
            availableVersionTitle: snapshot.availableVersionTitle,
            lastCheckedAtMs: snapshot.lastCheckedAtMs
        )
    }

    func makeHostSoftwareUpdateInstallResultMessage(
        from result: MirageHostSoftwareUpdateInstallResult
    ) -> HostSoftwareUpdateInstallResultMessage {
        HostSoftwareUpdateInstallResultMessage(
            accepted: result.accepted,
            message: result.message,
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
            currentVersion: appVersion ?? MirageKit.version,
            availableVersion: nil,
            availableVersionTitle: nil,
            lastCheckedAtMs: nil
        )
    }
}
#endif
