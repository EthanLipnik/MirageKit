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

public enum MirageLogCategory: String {
    case host
    case bootstrapHandoff
}

public enum MirageLogger {
    private static let subsystem = "com.ethanlipnik.MirageHostBootstrapDaemon"

    public static func bootstrapHandoff(_ message: String) {
        log(.bootstrapHandoff, message)
    }

    public static func host(_ message: String) {
        log(.host, message)
    }

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
