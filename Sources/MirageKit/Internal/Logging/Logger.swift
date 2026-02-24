//
//  Logger.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/5/26.
//

import Foundation
import os

public enum MirageLogLevel: String, Sendable {
    case info
    case debug
    case error
    case fault
}

/// Log categories for Mirage
/// Use MIRAGE_LOG environment variable to enable: "all", "none", or comma-separated list
public enum LogCategory: String, CaseIterable, Sendable {
    case timing // Frame capture/encode timing
    case metrics // Pipeline throughput metrics
    case capture // Screen capture engine
    case encoder // Video encoding
    case decoder // Video decoding
    case client // Client service operations
    case host // Host service operations
    case renderer // Metal rendering
    case appState // Application state
    case windowFilter // Window filtering logic
    case stream // Stream lifecycle
    case frameAssembly // Frame reassembly
    case discovery // Bonjour discovery
    case network // Network/advertiser operations
    case accessibility // Accessibility permission
    case windowActivator // Window activation
    case menuBar // Menu bar streaming
    case bootstrap // Client wake/unlock bootstrap orchestration
    case ssh // SSH bootstrap transport
    case wol // Wake-on-LAN transport
    case bootstrapHandoff = "bootstrap_handoff" // Bootstrap-to-normal-connect handoff
}

/// Centralized logging for Mirage using Apple's unified logging system (`Logger`)
///
/// Logs appear in Console.app under the "com.mirage" subsystem, filtered by category.
///
/// Set `MIRAGE_LOG` environment variable in Xcode scheme:
/// - `all` - Enable all log categories
/// - `none` - Disable all logging (except errors)
/// - `metrics,timing,encoder` - Enable specific categories (comma-separated)
/// - Not set - Default: essential logs only (host, client, appState)
public struct MirageLogger: Sendable {
    /// Subsystem identifier for the system logger (appears in Console.app)
    private static let subsystem = "com.mirage"

    /// Cached system logger instances per category (created lazily)
    private static let loggers: [LogCategory: Logger] = {
        var result: [LogCategory: Logger] = [:]
        for category in LogCategory.allCases {
            result[category] = Logger(subsystem: subsystem, category: category.rawValue)
        }
        return result
    }()

    /// Enabled log categories (evaluated once at startup from env var)
    public static let enabledCategories: Set<LogCategory> = parseEnvironment()

    /// Check if a category is enabled
    public static func isEnabled(_ category: LogCategory) -> Bool {
        enabledCategories.contains(category)
    }

    /// Log a message if the category is enabled
    /// Uses @autoclosure to avoid string interpolation when logging is disabled
    public static func log(
        _ category: LogCategory,
        _ message: @autoclosure () -> String,
        fileID: String = #fileID,
        line: UInt = #line,
        function: String = #function
    ) {
        logInfo(
            category,
            message: message,
            fileID: fileID,
            line: line,
            function: function
        )
    }

    /// Log a debug-level message (lower priority, filtered by default in Console.app)
    public static func debug(
        _ category: LogCategory,
        _ message: @autoclosure () -> String,
        fileID: String = #fileID,
        line: UInt = #line,
        function: String = #function
    ) {
        guard enabledCategories.contains(category) else { return }
        emit(
            category,
            level: .debug,
            message: message,
            fileID: fileID,
            line: line,
            function: function
        )
    }

    /// Log a message unconditionally (for errors).
    /// Errors are always logged regardless of category enablement.
    public static func error(
        _ category: LogCategory,
        _ message: @autoclosure () -> String,
        fileID: String = #fileID,
        line: UInt = #line,
        function: String = #function
    ) {
        emit(
            category,
            level: .error,
            message: message,
            fileID: fileID,
            line: line,
            function: function
        )
    }

    /// Log and report a structured non-fatal error.
    public static func error(
        _ category: LogCategory,
        error: Error,
        message: String? = nil,
        fileID: String = #fileID,
        line: UInt = #line,
        function: String = #function
    ) {
        emit(
            category,
            level: .error,
            message: {
                if let message, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return message
                }
                let metadata = MirageDiagnosticsErrorMetadata(error: error)
                return "type=\(metadata.typeName) domain=\(metadata.domain) code=\(metadata.code)"
            },
            fileID: fileID,
            line: line,
            function: function,
            underlyingError: error,
            errorSource: .logger
        )
    }

    /// Log a fault-level message (critical errors that indicate bugs).
    public static func fault(
        _ category: LogCategory,
        _ message: @autoclosure () -> String,
        fileID: String = #fileID,
        line: UInt = #line,
        function: String = #function
    ) {
        emit(
            category,
            level: .fault,
            message: message,
            fileID: fileID,
            line: line,
            function: function
        )
    }

    /// Log and report a structured fault.
    public static func fault(
        _ category: LogCategory,
        error: Error,
        message: String? = nil,
        fileID: String = #fileID,
        line: UInt = #line,
        function: String = #function
    ) {
        emit(
            category,
            level: .fault,
            message: {
                if let message, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return message
                }
                let metadata = MirageDiagnosticsErrorMetadata(error: error)
                return "type=\(metadata.typeName) domain=\(metadata.domain) code=\(metadata.code)"
            },
            fileID: fileID,
            line: line,
            function: function,
            underlyingError: error,
            errorSource: .logger
        )
    }

    private static func logInfo(
        _ category: LogCategory,
        message: () -> String,
        fileID: String,
        line: UInt,
        function: String
    ) {
        guard enabledCategories.contains(category) else { return }
        emit(
            category,
            level: .info,
            message: message,
            fileID: fileID,
            line: line,
            function: function
        )
    }

    private static func emit(
        _ category: LogCategory,
        level: MirageLogLevel,
        message: () -> String,
        fileID: String,
        line: UInt,
        function: String,
        underlyingError: Error? = nil,
        errorSource: MirageDiagnosticsErrorSource = .logger
    ) {
        let rawMessage = message()
        let sourceMessage = "\(sourcePrefix(fileID: fileID, line: line, function: function)) \(rawMessage)"
        let logger = logger(for: category)
        switch level {
        case .info:
            logger.info("\(sourceMessage, privacy: .public)")
        case .debug:
            logger.debug("\(sourceMessage, privacy: .public)")
        case .error:
            logger.error("\(sourceMessage, privacy: .public)")
        case .fault:
            logger.fault("\(sourceMessage, privacy: .public)")
        }

        let now = Date()
        MirageDiagnostics.record(log: MirageDiagnosticsLogEvent(
            date: now,
            category: category,
            level: level,
            message: sourceMessage,
            fileID: fileID,
            line: line,
            function: function
        ))

        switch level {
        case .error,
             .fault:
            MirageDiagnostics.record(error: MirageDiagnosticsErrorEvent(
                date: now,
                category: category,
                severity: level == .fault ? .fault : .error,
                source: errorSource,
                message: sourceMessage,
                fileID: fileID,
                line: line,
                function: function,
                metadata: underlyingError.map(MirageDiagnosticsErrorMetadata.init(error:))
            ))
        case .info,
             .debug:
            break
        }
    }

    private static func sourcePrefix(fileID: String, line: UInt, function: String) -> String {
        "[\(fileID):\(line) \(function)]"
    }

    private static func logger(for category: LogCategory) -> Logger {
        loggers[category] ?? Logger(subsystem: subsystem, category: category.rawValue)
    }

    /// Parse MIRAGE_LOG environment variable
    private static func parseEnvironment() -> Set<LogCategory> {
        guard let envValue = ProcessInfo.processInfo.environment["MIRAGE_LOG"] else {
            // Default: essential connection + client render/decode lifecycle logs
            return [.host, .client, .appState, .stream, .decoder, .renderer]
        }

        let trimmed = envValue.trimmingCharacters(in: .whitespaces).lowercased()

        switch trimmed {
        case "all":
            return Set(LogCategory.allCases)
        case "",
             "none":
            return []
        default:
            // Parse comma-separated list
            let names = trimmed.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            var categories: Set<LogCategory> = []
            for name in names {
                if let category = LogCategory(rawValue: name) { categories.insert(category) }
            }
            return categories
        }
    }
}

/// Convenience functions for common log patterns
public extension MirageLogger {
    /// Log timing information (frame processing, encoding duration, etc.)
    static func timing(
        _ message: @autoclosure () -> String,
        fileID: String = #fileID,
        line: UInt = #line,
        function: String = #function
    ) {
        logInfo(
            .timing,
            message: message,
            fileID: fileID,
            line: line,
            function: function
        )
    }

    /// Log pipeline throughput metrics
    static func metrics(
        _ message: @autoclosure () -> String,
        fileID: String = #fileID,
        line: UInt = #line,
        function: String = #function
    ) {
        logInfo(
            .metrics,
            message: message,
            fileID: fileID,
            line: line,
            function: function
        )
    }

    /// Log capture engine events
    static func capture(
        _ message: @autoclosure () -> String,
        fileID: String = #fileID,
        line: UInt = #line,
        function: String = #function
    ) {
        logInfo(
            .capture,
            message: message,
            fileID: fileID,
            line: line,
            function: function
        )
    }

    /// Log encoder events
    static func encoder(
        _ message: @autoclosure () -> String,
        fileID: String = #fileID,
        line: UInt = #line,
        function: String = #function
    ) {
        logInfo(
            .encoder,
            message: message,
            fileID: fileID,
            line: line,
            function: function
        )
    }

    /// Log decoder events
    static func decoder(
        _ message: @autoclosure () -> String,
        fileID: String = #fileID,
        line: UInt = #line,
        function: String = #function
    ) {
        logInfo(
            .decoder,
            message: message,
            fileID: fileID,
            line: line,
            function: function
        )
    }

    /// Log client events
    static func client(
        _ message: @autoclosure () -> String,
        fileID: String = #fileID,
        line: UInt = #line,
        function: String = #function
    ) {
        logInfo(
            .client,
            message: message,
            fileID: fileID,
            line: line,
            function: function
        )
    }

    /// Log host events
    static func host(
        _ message: @autoclosure () -> String,
        fileID: String = #fileID,
        line: UInt = #line,
        function: String = #function
    ) {
        logInfo(
            .host,
            message: message,
            fileID: fileID,
            line: line,
            function: function
        )
    }

    /// Log app state events
    static func appState(
        _ message: @autoclosure () -> String,
        fileID: String = #fileID,
        line: UInt = #line,
        function: String = #function
    ) {
        logInfo(
            .appState,
            message: message,
            fileID: fileID,
            line: line,
            function: function
        )
    }

    /// Log renderer events
    static func renderer(
        _ message: @autoclosure () -> String,
        fileID: String = #fileID,
        line: UInt = #line,
        function: String = #function
    ) {
        logInfo(
            .renderer,
            message: message,
            fileID: fileID,
            line: line,
            function: function
        )
    }

    /// Log stream lifecycle events
    static func stream(
        _ message: @autoclosure () -> String,
        fileID: String = #fileID,
        line: UInt = #line,
        function: String = #function
    ) {
        logInfo(
            .stream,
            message: message,
            fileID: fileID,
            line: line,
            function: function
        )
    }

    /// Log discovery events
    static func discovery(
        _ message: @autoclosure () -> String,
        fileID: String = #fileID,
        line: UInt = #line,
        function: String = #function
    ) {
        logInfo(
            .discovery,
            message: message,
            fileID: fileID,
            line: line,
            function: function
        )
    }

    /// Log network events
    static func network(
        _ message: @autoclosure () -> String,
        fileID: String = #fileID,
        line: UInt = #line,
        function: String = #function
    ) {
        logInfo(
            .network,
            message: message,
            fileID: fileID,
            line: line,
            function: function
        )
    }

    /// Log menu bar passthrough events
    static func menuBar(
        _ message: @autoclosure () -> String,
        fileID: String = #fileID,
        line: UInt = #line,
        function: String = #function
    ) {
        logInfo(
            .menuBar,
            message: message,
            fileID: fileID,
            line: line,
            function: function
        )
    }

    /// Log bootstrap orchestration events
    static func bootstrap(
        _ message: @autoclosure () -> String,
        fileID: String = #fileID,
        line: UInt = #line,
        function: String = #function
    ) {
        logInfo(
            .bootstrap,
            message: message,
            fileID: fileID,
            line: line,
            function: function
        )
    }

    /// Log SSH bootstrap events
    static func ssh(
        _ message: @autoclosure () -> String,
        fileID: String = #fileID,
        line: UInt = #line,
        function: String = #function
    ) {
        logInfo(
            .ssh,
            message: message,
            fileID: fileID,
            line: line,
            function: function
        )
    }

    /// Log Wake-on-LAN events
    static func wol(
        _ message: @autoclosure () -> String,
        fileID: String = #fileID,
        line: UInt = #line,
        function: String = #function
    ) {
        logInfo(
            .wol,
            message: message,
            fileID: fileID,
            line: line,
            function: function
        )
    }

    /// Log bootstrap handoff events
    static func bootstrapHandoff(
        _ message: @autoclosure () -> String,
        fileID: String = #fileID,
        line: UInt = #line,
        function: String = #function
    ) {
        logInfo(
            .bootstrapHandoff,
            message: message,
            fileID: fileID,
            line: line,
            function: function
        )
    }
}
