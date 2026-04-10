//
//  MirageClientService+Heartbeat.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/16/26.
//
//  Application-level heartbeat for fast host disappearance detection.
//

import Foundation
import MirageKit

enum ClientHeartbeatProbeDecision: Equatable {
    case waitForInboundActivity
    case skipActiveStream
    case skipGracePeriod
    case skipQualityTest
    case skipOperationInFlight
    case sendPing
}

func clientHeartbeatProbeDecision(
    inactivityDuration: CFAbsoluteTime,
    inactivityThreshold: CFAbsoluteTime,
    hasActiveStreams: Bool,
    isWithinGracePeriod: Bool,
    qualityTestActive: Bool,
    hasInFlightPingOrHostOperation: Bool
) -> ClientHeartbeatProbeDecision {
    guard !hasActiveStreams else { return .skipActiveStream }
    guard !isWithinGracePeriod else { return .skipGracePeriod }
    guard !qualityTestActive else { return .skipQualityTest }
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

                let latestInboundActivityTime = self.fastPathState.latestInboundActivityTime()
                let inactivityDuration = max(0, CFAbsoluteTimeGetCurrent() - latestInboundActivityTime)
                let decision = clientHeartbeatProbeDecision(
                    inactivityDuration: inactivityDuration,
                    inactivityThreshold: Self.heartbeatInactivityThreshold,
                    hasActiveStreams: !self.controllersByStream.isEmpty,
                    isWithinGracePeriod: self.heartbeatGraceDeadline.map { ContinuousClock.now < $0 } ?? false,
                    qualityTestActive: self.qualityTestPendingTestID != nil,
                    hasInFlightPingOrHostOperation: !self.pingContinuations.isEmpty ||
                        self.hostWallpaperContinuation != nil
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
