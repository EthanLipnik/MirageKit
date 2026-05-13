//
//  MirageClientService+ControlPath.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/9/26.
//
//  Client control-path telemetry and history.
//

import Foundation
import MirageKit

@MainActor
extension MirageClientService {
    nonisolated private static let controlPathHistoryLimit = 8

    // MARK: - Control Path Handling

    /// Stores the latest control path and records path switches.
    func handleControlPathUpdate(_ snapshot: MirageNetworkPathSnapshot) {
        let previous = controlPathSnapshot
        controlPathSnapshot = snapshot
        recordControlPathHistory(snapshot)
        guard let previous, previous.signature != snapshot.signature else { return }
        if previous.kind != snapshot.kind {
            awdlPathSwitches &+= 1
            MirageLogger.client(
                "Control path switch \(previous.kind.rawValue) -> \(snapshot.kind.rawValue) (count \(awdlPathSwitches))"
            )
        }
    }

    /// Emits throttled AWDL experiment metrics when steady-state diagnostics are enabled.
    func logAwdlExperimentTelemetryIfNeeded() {
        guard MirageSteadyStateDiagnostics.isEnabled else { return }
        let now = CFAbsoluteTimeGetCurrent()
        guard lastAwdlTelemetryLogTime == 0 || now - lastAwdlTelemetryLogTime >= 5.0 else { return }
        lastAwdlTelemetryLogTime = now
        MirageLogger.metrics(
            "AWDL telemetry: stalls=\(stallEvents), pathSwitches=\(awdlPathSwitches), hostRefreshReq=\(transportRefreshRequests), activeJitterHoldMs=\(activeJitterHoldMs)"
        )
    }

    /// Clears the bounded control-path history after disconnect or connection reset.
    func resetControlPathHistory() {
        controlPathHistory.removeAll(keepingCapacity: false)
    }

    /// Appends a distinct control-path status sample, keeping only the most recent entries.
    func recordControlPathHistory(
        _ snapshot: MirageNetworkPathSnapshot,
        observedAt: Date = Date()
    ) {
        let status = MirageClientNetworkPathStatus(snapshot: snapshot)
        guard controlPathHistory.last?.status != status else { return }

        controlPathHistory.append(
            MirageClientNetworkPathHistoryEntry(
                observedAt: observedAt,
                status: status
            )
        )
        if controlPathHistory.count > Self.controlPathHistoryLimit {
            controlPathHistory.removeFirst(controlPathHistory.count - Self.controlPathHistoryLimit)
        }
    }
}
