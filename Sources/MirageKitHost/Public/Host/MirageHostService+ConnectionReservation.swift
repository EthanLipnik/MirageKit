//
//  MirageHostService+ConnectionReservation.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/12/26.
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

#if os(macOS)

@MainActor
extension MirageHostService {
    /// Returns an already connected client context that conflicts with an incoming session.
    func busyClientContext(forIncomingSessionID sessionID: UUID) -> ClientContext? {
        clientsBySessionID.values.first { context in
            context.sessionID != sessionID
        }
    }

    /// Resolves why a busy host should reject an incoming takeover request, if at all.
    func busyHostTakeoverRejectionReason(
        for request: MirageWire.MirageSessionBootstrapRequest,
        trustEvaluation: MirageTrustEvaluationSnapshot,
        existingClient: MirageConnectedClient? = nil,
        incomingPeerIdentity: MirageAuthenticatedPeerIdentity? = nil
    ) -> MirageWire.MirageSessionBootstrapRejectionReason? {
        if let existingClient,
           let incomingPeerIdentity,
           shouldPreemptExistingClient(existingClient, for: incomingPeerIdentity) {
            MirageLogger.host(
                "Allowing same-device busy-host replacement existingClientID=\(existingClient.id.uuidString.lowercased()) " +
                    "incomingClientID=\(incomingPeerIdentity.deviceID.uuidString.lowercased())"
            )
            return nil
        }

        guard request.requestTakeoverIfBusy else {
            MirageLogger.host(
                "Rejecting busy-host connection without takeover request " +
                    "existingClientID=\(existingClient?.id.uuidString.lowercased() ?? "nil") " +
                    "incomingClientID=\(incomingPeerIdentity?.deviceID.uuidString.lowercased() ?? "nil")"
            )
            return .hostBusy
        }

        guard trustEvaluation.authorizesBusyHostTakeover else {
            MirageLogger.host(
                "Rejecting busy-host takeover by untrusted client trustDecision=\(trustEvaluation.decision.rawValue) " +
                    "existingClientID=\(existingClient?.id.uuidString.lowercased() ?? "nil") " +
                    "incomingClientID=\(incomingPeerIdentity?.deviceID.uuidString.lowercased() ?? "nil")"
            )
            return .takeoverRequiresTrustedRequester
        }

        MirageLogger.host(
            "Allowing trusted busy-host takeover " +
                "existingClientID=\(existingClient?.id.uuidString.lowercased() ?? "nil") " +
                "incomingClientID=\(incomingPeerIdentity?.deviceID.uuidString.lowercased() ?? "nil")"
        )
        return nil
    }

    /// Returns whether an incoming peer should supersede an existing connected client.
    func shouldPreemptExistingClient(
        _ existingClient: MirageConnectedClient,
        for incomingPeerIdentity: MirageAuthenticatedPeerIdentity
    ) -> Bool {
        existingClient.id == incomingPeerIdentity.deviceID
    }

    /// Disconnects an existing client when the same trusted device reconnects.
    func preemptExistingClientIfSuperseded(by incomingPeerIdentity: MirageAuthenticatedPeerIdentity) async {
        guard let existingClient = clientsBySessionID.values.first?.client else { return }
        guard shouldPreemptExistingClient(existingClient, for: incomingPeerIdentity) else { return }

        MirageLogger.host(
            "Preempting existing client \(existingClient.name) for reconnect from \(incomingPeerIdentity.displayName)"
        )
        await disconnectClient(existingClient)
    }

    /// Waits briefly for an in-flight disconnect to finish before accepting a reconnect.
    func waitForDisconnectCompletionIfNeeded(
        for incomingPeerIdentity: MirageAuthenticatedPeerIdentity,
        timeout: Duration = .seconds(5)
    ) async {
        guard shouldWaitForDisconnectCompletion(for: incomingPeerIdentity) else { return }

        let deadline = ContinuousClock.now + timeout
        MirageLogger.host(
            "Waiting for disconnect teardown to finish before accepting reconnect from \(incomingPeerIdentity.displayName)"
        )

        while shouldWaitForDisconnectCompletion(for: incomingPeerIdentity) {
            if ContinuousClock.now >= deadline {
                MirageLogger.host(
                    "Timed out waiting for disconnect teardown before reconnect from \(incomingPeerIdentity.displayName)"
                )
                return
            }

            do {
                try await Task.sleep(for: .milliseconds(50))
            } catch {
                return
            }
        }
    }

    private func shouldWaitForDisconnectCompletion(for incomingPeerIdentity: MirageAuthenticatedPeerIdentity) -> Bool {
        if disconnectingClientIDs.contains(incomingPeerIdentity.deviceID) {
            return true
        }

        guard let existingClient = connectedClients.first(where: {
            shouldPreemptExistingClient($0, for: incomingPeerIdentity)
        }) else {
            return false
        }

        return disconnectingClientIDs.contains(existingClient.id)
    }

    /// Expires an orphaned single-client slot reservation after the approval timeout.
    func expireStaleSingleClientReservationIfNeeded(now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) {
        guard let reservedSessionID = singleClientSessionID,
              clientsBySessionID.isEmpty,
              connectedClients.isEmpty,
              disconnectingClientIDs.isEmpty,
              let reservationStartedAt = singleClientReservationStartedAt,
              now - reservationStartedAt >= connectionApprovalTimeoutSeconds else {
            return
        }

        MirageLogger.host(
            "Expiring stale client slot reservation \(reservedSessionID.uuidString) after \(now - reservationStartedAt)s"
        )
        releaseSingleClientSlot(
            for: reservedSessionID,
            clientID: nil,
            reason: "reservation-expired"
        )
    }

    /// Schedules reservation expiry so a stalled bootstrap does not leave the host advertised as busy.
    func scheduleSingleClientReservationExpiry(for sessionID: UUID) {
        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = singleClientReservationStartedAt.map { now - $0 } ?? 0
        let delaySeconds = max(0, connectionApprovalTimeoutSeconds - elapsed)
        Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(delaySeconds))
            } catch {
                return
            }
            guard let self else { return }
            guard self.singleClientSessionID == sessionID else { return }
            self.expireStaleSingleClientReservationIfNeeded()
        }
    }

    /// Reserves the host's single-client slot for a bootstrapping session.
    func reserveSingleClientSlot(for sessionID: UUID) -> Bool {
        expireStaleSingleClientReservationIfNeeded()

        if let reservedID = singleClientSessionID, reservedID != sessionID { return false }

        if let existingSessionID = clientsBySessionID.keys.first, existingSessionID != sessionID {
            singleClientSessionID = existingSessionID
            return false
        }

        singleClientSessionID = sessionID
        scheduleSingleClientReservationExpiry(for: sessionID)
        return true
    }

    /// Releases the single-client slot if it is still owned by the supplied session.
    func releaseSingleClientSlot(
        for sessionID: UUID,
        clientID: UUID? = nil,
        reason: String = "unspecified"
    ) {
        guard singleClientSessionID == sessionID else { return }
        MirageLogger.host(
            "Releasing single-client slot sessionID=\(sessionID.uuidString) "
                + "clientID=\(clientID?.uuidString ?? "nil") "
                + "reason=\(reason) "
                + "clientsBySessionIDEmpty=\(clientsBySessionID.isEmpty) "
                + "connectedClientsEmpty=\(connectedClients.isEmpty)"
        )
        singleClientSessionID = nil
    }
}

#endif
