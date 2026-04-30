//
//  MirageHostService+Heartbeat.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/5/26.
//
//  Host-side client liveness monitoring.
//

import Foundation
import MirageKit

#if os(macOS)
@MainActor
extension MirageHostService {
    /// How often the liveness monitor checks connected clients.
    private static let livenessCheckInterval: Duration = .seconds(5)

    /// How long since the last received data before proactively pinging.
    private static let livenessPingThreshold: CFAbsoluteTime = 10.0

    /// How long since the last received data before disconnecting.
    private static let livenessDisconnectThreshold: CFAbsoluteTime = 20.0

    nonisolated private static let minimumBackgroundLeaseDuration: TimeInterval = 1
    nonisolated private static let maximumBackgroundLeaseDuration: TimeInterval = 30

    nonisolated func recordClientActivity(clientID: UUID) {
        clientLastActivityByID.withLock { $0[clientID] = CFAbsoluteTimeGetCurrent() }
    }

    nonisolated static func clampedBackgroundLeaseDuration(_ duration: TimeInterval) -> TimeInterval {
        guard duration.isFinite else { return maximumBackgroundLeaseDuration }
        return min(max(duration, minimumBackgroundLeaseDuration), maximumBackgroundLeaseDuration)
    }

    func scheduleBackgroundLease(
        _ lease: ClientBackgroundLeaseMessage,
        for clientContext: ClientContext
    ) {
        let duration = Self.clampedBackgroundLeaseDuration(lease.durationSeconds)
        let expiration = Date().addingTimeInterval(duration)
        let client = clientContext.client
        let sessionID = clientContext.sessionID
        backgroundLeaseExpirationsByClientID[client.id] = expiration
        backgroundLeaseTasksByClientID[client.id]?.cancel()
        backgroundLeaseTasksByClientID[client.id] = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(Int(duration * 1000)))
            } catch {
                return
            }

            guard let self else { return }
            guard self.backgroundLeaseExpirationsByClientID[client.id] == expiration else { return }
            self.backgroundLeaseExpirationsByClientID.removeValue(forKey: client.id)
            self.backgroundLeaseTasksByClientID.removeValue(forKey: client.id)

            guard self.findClientContext(sessionID: sessionID)?.client.id == client.id else {
                return
            }

            MirageLogger.host(
                "Background lease expired for \(client.name); freeing host slot"
            )
            await self.disconnectClient(
                client,
                sessionID: sessionID,
                notifyClient: true,
                reason: .backgroundLeaseExpired,
                message: "Background lease expired."
            )
            self.delegate?.hostService(self, didDisconnectClient: client)
        }

        MirageLogger.host(
            "Background lease armed for \(client.name) leaseID=\(lease.leaseID.uuidString) duration=\(duration)s"
        )
    }

    func cancelBackgroundLease(clientID: UUID) {
        backgroundLeaseExpirationsByClientID.removeValue(forKey: clientID)
        backgroundLeaseTasksByClientID[clientID]?.cancel()
        backgroundLeaseTasksByClientID.removeValue(forKey: clientID)
    }

    func startClientLivenessMonitorIfNeeded() {
        guard clientLivenessTask == nil else { return }
        clientLivenessTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: Self.livenessCheckInterval)
                } catch {
                    return
                }
                guard let self else { return }
                await self.checkClientLiveness()
            }
        }
    }

    func stopClientLivenessMonitorIfIdle() {
        guard connectedClients.isEmpty else { return }
        clientLivenessTask?.cancel()
        clientLivenessTask = nil
    }

    func clearClientActivityRecord(clientID: UUID) {
        clientLastActivityByID.withLock { $0.removeValue(forKey: clientID) }
    }

    private func checkClientLiveness() async {
        let now = CFAbsoluteTimeGetCurrent()
        let activitySnapshot = clientLastActivityByID.read { $0 }

        for clientContext in clientsBySessionID.values {
            let clientID = clientContext.client.id
            guard !disconnectingClientIDs.contains(clientID) else { continue }

            let lastActivity = activitySnapshot[clientID] ?? 0
            let elapsed = now - lastActivity

            if elapsed >= Self.livenessDisconnectThreshold {
                MirageLogger.host(
                    "Client \(clientContext.client.name) liveness timeout (\(Int(elapsed))s idle) — disconnecting"
                )
                await disconnectClient(
                    clientContext.client,
                    sessionID: clientContext.sessionID,
                    notifyClient: false
                )
                delegate?.hostService(self, didDisconnectClient: clientContext.client)
            } else if elapsed >= Self.livenessPingThreshold {
                clientContext.sendBestEffort(ControlMessage(type: .ping))
            }
        }
    }
}
#endif
