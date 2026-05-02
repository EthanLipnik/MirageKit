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
enum HostClientLivenessDecision: Equatable {
    case wait
    case ping
    case deferForActiveMedia
    case disconnect
}

func hostClientLivenessDecision(
    controlIdleSeconds: CFAbsoluteTime,
    mediaIdleSeconds: CFAbsoluteTime?,
    hasActiveStreams: Bool,
    pingThreshold: CFAbsoluteTime,
    disconnectThreshold: CFAbsoluteTime,
    activeMediaGraceThreshold: CFAbsoluteTime
) -> HostClientLivenessDecision {
    guard controlIdleSeconds >= disconnectThreshold else {
        return controlIdleSeconds >= pingThreshold ? .ping : .wait
    }

    if hasActiveStreams,
       let mediaIdleSeconds,
       mediaIdleSeconds < activeMediaGraceThreshold {
        return .deferForActiveMedia
    }

    return .disconnect
}

@MainActor
extension MirageHostService {
    /// How often the liveness monitor checks connected clients.
    private static let livenessCheckInterval: Duration = .seconds(5)

    /// How long since the last received data before proactively pinging.
    private static let livenessPingThreshold: CFAbsoluteTime = 10.0

    /// How long since the last received data before disconnecting.
    private static let livenessDisconnectThreshold: CFAbsoluteTime = 20.0

    /// How recent host media activity must be to keep an active stream alive
    /// while the control channel is otherwise quiet.
    private static let livenessActiveMediaGraceThreshold: CFAbsoluteTime = 8.0

    nonisolated private static let minimumBackgroundLeaseDuration: TimeInterval = 1
    nonisolated private static let maximumBackgroundLeaseDuration: TimeInterval = 30

    nonisolated func recordClientActivity(clientID: UUID) {
        clientLastActivityByID.withLock { $0[clientID] = CFAbsoluteTimeGetCurrent() }
    }

    nonisolated func recordClientMediaActivity(clientID: UUID) {
        clientLastMediaActivityByID.withLock { $0[clientID] = CFAbsoluteTimeGetCurrent() }
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
        clientLastMediaActivityByID.withLock { $0.removeValue(forKey: clientID) }
    }

    private func checkClientLiveness() async {
        let now = CFAbsoluteTimeGetCurrent()
        let activitySnapshot = clientLastActivityByID.read { $0 }
        let mediaActivitySnapshot = clientLastMediaActivityByID.read { $0 }

        for clientContext in clientsBySessionID.values {
            let clientID = clientContext.client.id
            guard !disconnectingClientIDs.contains(clientID) else { continue }

            let lastActivity = activitySnapshot[clientID] ?? 0
            let elapsed = now - lastActivity
            let mediaElapsed = mediaActivitySnapshot[clientID].map { now - $0 }
            let hasActiveStreams = hasActiveStream(forClientID: clientID)

            switch hostClientLivenessDecision(
                controlIdleSeconds: elapsed,
                mediaIdleSeconds: mediaElapsed,
                hasActiveStreams: hasActiveStreams,
                pingThreshold: Self.livenessPingThreshold,
                disconnectThreshold: Self.livenessDisconnectThreshold,
                activeMediaGraceThreshold: Self.livenessActiveMediaGraceThreshold
            ) {
            case .wait:
                break
            case .ping:
                clientContext.sendBestEffort(ControlMessage(type: .ping))
            case .deferForActiveMedia:
                MirageLogger.host(
                    "Client \(clientContext.client.name) liveness timeout deferred; active media was sent \(Int(mediaElapsed ?? 0))s ago"
                )
                clientContext.sendBestEffort(ControlMessage(type: .ping))
            case .disconnect:
                MirageLogger.host(
                    "Client \(clientContext.client.name) liveness timeout (\(Int(elapsed))s idle) — disconnecting"
                )
                await disconnectClient(
                    clientContext.client,
                    sessionID: clientContext.sessionID,
                    notifyClient: false
                )
                delegate?.hostService(self, didDisconnectClient: clientContext.client)
            }
        }
    }

    private func hasActiveStream(forClientID clientID: UUID) -> Bool {
        if let desktopClientID = desktopStreamClientContext?.client.id,
           desktopClientID == clientID,
           desktopStreamContext != nil {
            return true
        }

        return activeSessionByStreamID.values.contains { $0.client.id == clientID } ||
            customStreamClientSessionIDByStreamID.values.contains { sessionID in
                clientsBySessionID[sessionID]?.client.id == clientID
            }
    }
}
#endif
