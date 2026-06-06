//
//  MirageClientService+Heartbeat.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/16/26.
//
//  Application-level heartbeat for fast host disappearance detection.
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

/// Explains why the client heartbeat loop should send or skip a reachability ping.
enum ClientHeartbeatProbeDecision: Equatable {
    case waitForInboundActivity
    case skipActiveStream
    case skipGracePeriod
    case skipOperationInFlight
    case sendPing
}

/// Decides whether an idle connected client should probe the host for liveness.
///
/// Heartbeats are suppressed while other traffic or setup work can already prove the
/// host is reachable, so pings only run after the connection has been quiet long
/// enough to exceed the inactivity threshold.
func clientHeartbeatProbeDecision(
    inactivityDuration: CFAbsoluteTime,
    inactivityThreshold: CFAbsoluteTime,
    hasActiveStreams: Bool,
    hasPendingStreamSetup: Bool,
    isWithinGracePeriod: Bool,
    hasInFlightPingOrHostOperation: Bool
) -> ClientHeartbeatProbeDecision {
    guard !hasActiveStreams else { return .skipActiveStream }
    guard !hasPendingStreamSetup else { return .skipOperationInFlight }
    guard !isWithinGracePeriod else { return .skipGracePeriod }
    guard !hasInFlightPingOrHostOperation else { return .skipOperationInFlight }
    guard inactivityDuration >= inactivityThreshold else { return .waitForInboundActivity }
    return .sendPing
}

@MainActor
extension MirageClientService {
    private static let heartbeatInterval: Duration = .seconds(5)
    private static let heartbeatInactivityThreshold: CFAbsoluteTime = 10
    private static let heartbeatPingTimeout: Duration = .seconds(5)
    private static let heartbeatMaxConsecutiveFailures = 2

    func startHeartbeat() {
        stopHeartbeat()
        heartbeatTask = Task { [weak self] in
            guard let self else { return }
            var consecutiveFailures = 0

            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: Self.heartbeatInterval)
                } catch {
                    return
                }
                guard case .connected = self.connectionState else { return }

                let latestInboundActivityTime = self.fastPathState.latestInboundActivityTime
                let inactivityDuration = max(0, CFAbsoluteTimeGetCurrent() - latestInboundActivityTime)
                let hasInFlightHostOperation = self.hostWallpaperContinuation != nil ||
                    self.hostSupportLogArchiveContinuation != nil
                let decision = clientHeartbeatProbeDecision(
                    inactivityDuration: inactivityDuration,
                    inactivityThreshold: Self.heartbeatInactivityThreshold,
                    hasActiveStreams: !self.controllersByStream.isEmpty,
                    hasPendingStreamSetup: self.pendingStreamSetupRequestID != nil,
                    isWithinGracePeriod: self.heartbeatGraceDeadline.map { ContinuousClock.now < $0 } ?? false,
                    hasInFlightPingOrHostOperation: !self.pingContinuations.isEmpty || hasInFlightHostOperation
                )
                guard decision == .sendPing else {
                    consecutiveFailures = 0
                    continue
                }

                do {
                    try await self.sendPingAndAwaitPong(timeout: Self.heartbeatPingTimeout)
                    consecutiveFailures = 0
                } catch {
                    consecutiveFailures += 1
                    MirageLogger.client(
                        "Heartbeat ping failed (\(consecutiveFailures)/\(Self.heartbeatMaxConsecutiveFailures)): \(error.localizedDescription)"
                    )
                    if consecutiveFailures >= Self.heartbeatMaxConsecutiveFailures {
                        MirageLogger.client(
                            "Heartbeat detected host disappearance after \(consecutiveFailures) consecutive failures"
                        )
                        await self.handleDisconnect(
                            reason: "Host became unreachable",
                            state: .error("Host became unreachable"),
                            notifyDelegate: true
                        )
                        return
                    }
                }
            }
        }
    }

    func stopHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
    }
}
