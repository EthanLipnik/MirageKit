//
//  MirageBootstrapDaemonTelemetry.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/3/26.
//
//  Daemon telemetry coordinator that writes analytics/diagnostics events to app-group queue.
//

import Foundation
import Loom

#if os(macOS)

/// Telemetry queue used by the bootstrap daemon for app-group handoff.
public enum MirageBootstrapDaemonTelemetry {
    /// Configures the app group used for telemetry handoff.
    public static func configure(appGroupIdentifier: String) {
        Task {
            await shared.configure(appGroupIdentifier: appGroupIdentifier)
        }
    }

    /// Enables or disables diagnostic event recording.
    public static func setDiagnosticsEnabled(_ enabled: Bool) {
        Task {
            await shared.setDiagnosticsEnabled(enabled)
        }
    }

    /// Records a daemon analytics event.
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

    /// Records a daemon diagnostic event.
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
        kind: LoomBootstrapTelemetryEventKind,
        eventName: String,
        message: String?,
        metadata: [String: String]
    ) async {
        guard let writer else { return }
        if kind == .diagnostic, !diagnosticsEnabled { return }

        let event = LoomBootstrapTelemetryEventEnvelope(
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
