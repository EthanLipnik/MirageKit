//
//  MirageHostService+ConnectionReservation.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/12/26.
//

import Foundation
import Loom
import MirageKit

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
        for request: MirageSessionBootstrapRequest,
        trustEvaluation: LoomTrustEvaluation,
        existingClient: MirageConnectedClient? = nil,
        incomingPeerIdentity: LoomPeerIdentity? = nil
    ) -> MirageSessionBootstrapRejectionReason? {
        if let existingClient,
           let incomingPeerIdentity,
           shouldPreemptExistingClient(existingClient, for: incomingPeerIdentity) {
            return nil
        }

        guard request.requestTakeoverIfBusy else {
            return .hostBusy
        }

        guard trustEvaluation.decision == .trusted else {
            return .takeoverRequiresTrustedRequester
        }

        return nil
    }

    /// Returns whether an incoming peer should supersede an existing connected client.
    func shouldPreemptExistingClient(
        _ existingClient: MirageConnectedClient,
        for incomingPeerIdentity: LoomPeerIdentity
    ) -> Bool {
        existingClient.id == incomingPeerIdentity.deviceID
    }

    /// Disconnects an existing client when the same trusted device reconnects.
    func preemptExistingClientIfSuperseded(by incomingPeerIdentity: LoomPeerIdentity) async {
        guard let existingClient = clientsBySessionID.values.first?.client else { return }
        guard shouldPreemptExistingClient(existingClient, for: incomingPeerIdentity) else { return }

        MirageLogger.host(
            "Preempting existing client \(existingClient.name) for reconnect from \(incomingPeerIdentity.name)"
        )
        await disconnectClient(existingClient)
    }

    /// Waits briefly for an in-flight disconnect to finish before accepting a reconnect.
    func waitForDisconnectCompletionIfNeeded(
        for incomingPeerIdentity: LoomPeerIdentity,
        timeout: Duration = .seconds(5)
    ) async {
        guard shouldWaitForDisconnectCompletion(for: incomingPeerIdentity) else { return }

        let deadline = ContinuousClock.now + timeout
        MirageLogger.host(
            "Waiting for disconnect teardown to finish before accepting reconnect from \(incomingPeerIdentity.name)"
        )

        while shouldWaitForDisconnectCompletion(for: incomingPeerIdentity) {
            if ContinuousClock.now >= deadline {
                MirageLogger.host(
                    "Timed out waiting for disconnect teardown before reconnect from \(incomingPeerIdentity.name)"
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

    private func shouldWaitForDisconnectCompletion(for incomingPeerIdentity: LoomPeerIdentity) -> Bool {
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
