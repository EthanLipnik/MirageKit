//
//  MirageLogger.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/3/26.
//
//  Local daemon logger independent of Mirage app diagnostics pipeline.
//

import Foundation
import OSLog

#if os(macOS)

/// Logging categories emitted by the bootstrap daemon.
public enum MirageLogCategory: String {
    /// Host lifecycle and runtime events.
    case host
    /// Bootstrap handoff events exchanged with the app.
    case bootstrapHandoff
}

/// Logger used by the bootstrap daemon before the full app diagnostics pipeline is available.
public enum MirageLogger {
    private static let subsystem = "com.ethanlipnik.MirageHostBootstrapDaemon"

    /// Records a bootstrap handoff message.
    public static func bootstrapHandoff(_ message: String) {
        log(.bootstrapHandoff, message)
    }

    /// Records a host runtime message.
    public static func host(_ message: String) {
        log(.host, message)
    }

    /// Records an informational daemon log entry.
    public static func log(_ category: MirageLogCategory, _ message: String) {
        Logger(subsystem: subsystem, category: category.rawValue).log("\(message, privacy: .public)")
        MirageBootstrapDaemonTelemetry.recordDiagnostic(
            eventName: "mirage.daemon.log",
            message: message,
            metadata: [
                "category": category.rawValue,
                "level": "info",
            ]
        )
    }

    /// Records a daemon error message.
    public static func error(_ category: MirageLogCategory, _ message: String) {
        Logger(subsystem: subsystem, category: category.rawValue).error("\(message, privacy: .public)")
        MirageBootstrapDaemonTelemetry.recordDiagnostic(
            eventName: "mirage.daemon.error",
            message: message,
            metadata: [
                "category": category.rawValue,
                "level": "error",
            ]
        )
    }

    /// Records a daemon error with the underlying Swift error type.
    public static func error(
        _ category: MirageLogCategory,
        error: Error,
        message: String
    ) {
        let combinedMessage = "\(message)\(error.localizedDescription)"
        Logger(subsystem: subsystem, category: category.rawValue).error("\(combinedMessage, privacy: .public)")
        MirageBootstrapDaemonTelemetry.recordDiagnostic(
            eventName: "mirage.daemon.error",
            message: combinedMessage,
            metadata: [
                "category": category.rawValue,
                "level": "error",
                "errorType": String(reflecting: type(of: error)),
            ]
        )
    }
}

#endif
