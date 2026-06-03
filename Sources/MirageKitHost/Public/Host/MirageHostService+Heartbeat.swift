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
/// Liveness action chosen for a connected host client.
enum HostClientLivenessDecision: Equatable {
    case wait
    case ping
    case deferForBackgroundLease
    case deferForActiveMedia
    case deferForActiveControlWork
    case disconnect
}

/// Chooses the next liveness action from control, media, background, and metadata activity.
func hostClientLivenessDecision(
    controlIdleSeconds: CFAbsoluteTime,
    mediaIdleSeconds: CFAbsoluteTime?,
    hasActiveStreams: Bool,
    pingThreshold: CFAbsoluteTime,
    disconnectThreshold: CFAbsoluteTime,
    activeMediaGraceThreshold: CFAbsoluteTime,
    hasActiveBackgroundLease: Bool = false,
    controlWorkIdleSeconds: CFAbsoluteTime? = nil,
    hasActiveControlWork: Bool = false,
    activeControlWorkGraceThreshold: CFAbsoluteTime = 8.0
) -> HostClientLivenessDecision {
    guard controlIdleSeconds >= disconnectThreshold else {
        return controlIdleSeconds >= pingThreshold ? .ping : .wait
    }

    if hasActiveStreams,
       let mediaIdleSeconds,
       mediaIdleSeconds < activeMediaGraceThreshold {
        return .deferForActiveMedia
    }

    if hasActiveBackgroundLease {
        return .deferForBackgroundLease
    }

    if hasActiveControlWork,
       let controlWorkIdleSeconds,
       controlWorkIdleSeconds < activeControlWorkGraceThreshold {
        return .deferForActiveControlWork
    }

    return .disconnect
}

/// Returns whether background state should defer client liveness disconnects.
func hostHasActiveBackgroundLease(
    timedExpiration: Date?,
    hasSuspendedLease: Bool,
    hasActiveStreams: Bool,
    now: Date
) -> Bool {
    if hasSuspendedLease, hasActiveStreams {
        return true
    }
    return timedExpiration.map { $0 > now } ?? false
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

    /// How recent host control traffic must be to keep metadata-heavy control
    /// work from being treated as an idle client.
    private static let livenessActiveControlWorkGraceThreshold: CFAbsoluteTime = 8.0

    nonisolated private static let minimumBackgroundLeaseDuration: TimeInterval = 1
    nonisolated private static let maximumBackgroundLeaseDuration: TimeInterval = 120

    /// Records inbound control-channel activity for a client.
    nonisolated func recordClientActivity(clientID: UUID) {
        clientLastActivityByID.withLock { $0[clientID] = CFAbsoluteTimeGetCurrent() }
    }

    /// Records host media delivery activity for a client.
    nonisolated func recordClientMediaActivity(clientID: UUID) {
        clientLastMediaActivityByID.withLock { $0[clientID] = CFAbsoluteTimeGetCurrent() }
    }

    /// Records outbound control-channel activity for a client.
    nonisolated func recordClientControlSendActivity(clientID: UUID) {
        clientLastControlSendActivityByID.withLock { $0[clientID] = CFAbsoluteTimeGetCurrent() }
    }

    /// Clamps a background lease request to the host's accepted duration range.
    nonisolated static func clampedBackgroundLeaseDuration(_ duration: TimeInterval) -> TimeInterval {
        guard duration.isFinite else { return maximumBackgroundLeaseDuration }
        return min(max(duration, minimumBackgroundLeaseDuration), maximumBackgroundLeaseDuration)
    }

    /// Arms a temporary lease that lets a backgrounded client keep its host slot.
    func scheduleBackgroundLease(
        _ lease: ClientBackgroundLeaseMessage,
        for clientContext: ClientContext
    ) {
        if lease.mode == .suspendedUntilForeground {
            let client = clientContext.client
            backgroundLeaseExpirationsByClientID.removeValue(forKey: client.id)
            backgroundLeaseTasksByClientID[client.id]?.cancel()
            backgroundLeaseTasksByClientID.removeValue(forKey: client.id)
            suspendedBackgroundLeaseIDsByClientID[client.id] = lease.leaseID
            MirageLogger.host(
                "Background suspended-stream lease armed for \(client.name) leaseID=\(lease.leaseID.uuidString)"
            )
            return
        }

        let duration = Self.clampedBackgroundLeaseDuration(lease.durationSeconds)
        let expiration = Date().addingTimeInterval(duration)
        let client = clientContext.client
        let sessionID = clientContext.sessionID
        suspendedBackgroundLeaseIDsByClientID.removeValue(forKey: client.id)
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
                reason: .backgroundLeaseExpired
            )
            self.delegate?.didDisconnectClient(client)
        }

        MirageLogger.host(
            "Background lease armed for \(client.name) leaseID=\(lease.leaseID.uuidString) duration=\(duration)s"
        )
    }

    /// Cancels any background lease for a client.
    func cancelBackgroundLease(clientID: UUID) {
        backgroundLeaseExpirationsByClientID.removeValue(forKey: clientID)
        suspendedBackgroundLeaseIDsByClientID.removeValue(forKey: clientID)
        backgroundLeaseTasksByClientID[clientID]?.cancel()
        backgroundLeaseTasksByClientID.removeValue(forKey: clientID)
    }

    /// Starts the client liveness monitor while at least one client is connected.
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

    /// Stops the client liveness monitor once all clients are gone.
    func stopClientLivenessMonitorIfIdle() {
        guard connectedClients.isEmpty else { return }
        clientLivenessTask?.cancel()
        clientLivenessTask = nil
    }

    /// Clears all liveness activity timestamps for a client.
    func clearClientActivityRecord(clientID: UUID) {
        clientLastActivityByID.withLock { $0[clientID] = nil }
        clientLastMediaActivityByID.withLock { $0[clientID] = nil }
        clientLastControlSendActivityByID.withLock { $0[clientID] = nil }
    }

    /// Checks connected clients and disconnects those that exceeded the idle deadline.
    private func checkClientLiveness() async {
        let now = CFAbsoluteTimeGetCurrent()
        let activitySnapshot = clientLastActivityByID.read { $0 }
        let mediaActivitySnapshot = clientLastMediaActivityByID.read { $0 }
        let controlSendActivitySnapshot = clientLastControlSendActivityByID.read { $0 }
        let nowDate = Date()

        for clientContext in clientsBySessionID.values {
            let clientID = clientContext.client.id
            guard !disconnectingClientIDs.contains(clientID) else { continue }

            let lastActivity = activitySnapshot[clientID] ?? 0
            let elapsed = now - lastActivity
            let mediaElapsed = mediaActivitySnapshot[clientID].map { now - $0 }
            let controlWorkElapsed = controlSendActivitySnapshot[clientID].map { now - $0 }
            let hasActiveStreams = hasActiveStream(forClientID: clientID)
            let hasActiveControlWork = appListRequestTask != nil && pendingAppListRequest?.clientID == clientID
            let hasActiveBackgroundLease = hostHasActiveBackgroundLease(
                timedExpiration: backgroundLeaseExpirationsByClientID[clientID],
                hasSuspendedLease: suspendedBackgroundLeaseIDsByClientID[clientID] != nil,
                hasActiveStreams: hasActiveStreams,
                now: nowDate
            )

            switch hostClientLivenessDecision(
                controlIdleSeconds: elapsed,
                mediaIdleSeconds: mediaElapsed,
                hasActiveStreams: hasActiveStreams,
                pingThreshold: Self.livenessPingThreshold,
                disconnectThreshold: Self.livenessDisconnectThreshold,
                activeMediaGraceThreshold: Self.livenessActiveMediaGraceThreshold,
                hasActiveBackgroundLease: hasActiveBackgroundLease,
                controlWorkIdleSeconds: controlWorkElapsed,
                hasActiveControlWork: hasActiveControlWork,
                activeControlWorkGraceThreshold: Self.livenessActiveControlWorkGraceThreshold
            ) {
            case .wait:
                break
            case .ping:
                clientContext.sendBestEffort(.ping)
            case .deferForBackgroundLease:
                MirageLogger.host(
                    "Client \(clientContext.client.name) liveness timeout deferred; background lease is active"
                )
            case .deferForActiveMedia:
                MirageLogger.host(
                    "Client \(clientContext.client.name) liveness timeout deferred; active media was sent \(Int(mediaElapsed ?? 0))s ago"
                )
                clientContext.sendBestEffort(.ping)
            case .deferForActiveControlWork:
                MirageLogger.host(
                    "Client \(clientContext.client.name) liveness timeout deferred; active control work was sent \(Int(controlWorkElapsed ?? 0))s ago"
                )
                clientContext.sendBestEffort(.ping)
            case .disconnect:
                MirageLogger.host(
                    "Client \(clientContext.client.name) liveness timeout (\(Int(elapsed))s idle) — disconnecting"
                )
                await disconnectClient(
                    clientContext.client,
                    sessionID: clientContext.sessionID,
                    notifyClient: false
                )
                delegate?.didDisconnectClient(clientContext.client)
            }
        }
    }

    /// Returns whether a client owns any active media stream.
    private func hasActiveStream(forClientID clientID: UUID) -> Bool {
        (desktopStreamClientContext?.client.id == clientID && desktopStreamContext != nil) ||
            activeSessionByStreamID.values.contains { $0.client.id == clientID } ||
            customStreamClientSessionIDByStreamID.values.contains { sessionID in
                clientsBySessionID[sessionID]?.client.id == clientID
            }
    }
}
#endif
