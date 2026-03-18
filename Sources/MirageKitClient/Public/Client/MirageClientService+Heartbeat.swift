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

@MainActor
extension MirageClientService {
    private static let heartbeatInterval: Duration = .seconds(2)
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

                // Active streams provide their own liveness signal via UDP packet flow.
                guard self.controllersByStream.isEmpty else {
                    consecutiveFailures = 0
                    continue
                }

                // A quality-test ping already in flight proves the connection is alive.
                guard self.pingContinuation == nil else {
                    consecutiveFailures = 0
                    continue
                }

                do {
                    try await self.sendPingAndAwaitPong()
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
