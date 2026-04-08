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

    nonisolated func recordClientActivity(clientID: UUID) {
        clientLastActivityByID.withLock { $0[clientID] = CFAbsoluteTimeGetCurrent() }
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
                await disconnectClient(clientContext.client, sessionID: clientContext.sessionID)
                delegate?.hostService(self, didDisconnectClient: clientContext.client)
            } else if elapsed >= Self.livenessPingThreshold {
                clientContext.sendBestEffort(ControlMessage(type: .ping))
            }
        }
    }
}
#endif
