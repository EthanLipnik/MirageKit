//
//  MirageBootstrapDaemonTelemetry.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/3/26.
//
//  Daemon telemetry coordinator that writes analytics/diagnostics events to app-group queue.
//

import Foundation
import MirageBootstrapShared

#if os(macOS)

public enum MirageBootstrapDaemonTelemetry {
    public static func configure(appGroupIdentifier: String) {
        Task {
            await shared.configure(appGroupIdentifier: appGroupIdentifier)
        }
    }

    public static func setDiagnosticsEnabled(_ enabled: Bool) {
        Task {
            await shared.setDiagnosticsEnabled(enabled)
        }
    }

    public static func recordAnalytics(
        eventName: String,
        message: String? = nil,
        metadata: [String: String] = [:]
    ) {
        Task {
            await shared.record(
                kind: .analytics,
                eventName: eventName,
                message: message,
                metadata: metadata
            )
        }
    }

    public static func recordDiagnostic(
        eventName: String,
        message: String,
        metadata: [String: String] = [:]
    ) {
        Task {
            await shared.record(
                kind: .diagnostic,
                eventName: eventName,
                message: message,
                metadata: metadata
            )
        }
    }

    private static let shared = MirageBootstrapDaemonTelemetryCoordinator()
}

private actor MirageBootstrapDaemonTelemetryCoordinator {
    private var writer: MirageBootstrapTelemetryQueueWriter?
    private var diagnosticsEnabled = false

    func configure(appGroupIdentifier: String) {
        writer = MirageBootstrapTelemetryQueueWriter(appGroupIdentifier: appGroupIdentifier)
    }

    func setDiagnosticsEnabled(_ enabled: Bool) {
        diagnosticsEnabled = enabled
    }

    func record(
        kind: MirageBootstrapTelemetryEventKind,
        eventName: String,
        message: String?,
        metadata: [String: String]
    ) async {
        guard let writer else { return }
        if kind == .diagnostic, !diagnosticsEnabled { return }

        let event = MirageBootstrapTelemetryEventEnvelope(
            kind: kind,
            eventName: eventName,
            message: message,
            metadata: metadata,
            source: .daemon
        )
        await writer.append(event)
    }
}

#endif
