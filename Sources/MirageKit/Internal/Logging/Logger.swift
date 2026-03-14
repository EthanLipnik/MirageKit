//
//  Logger.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/5/26.
//

import Foundation
import Loom
import os

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
    public struct SignpostInterval {
        fileprivate let category: MirageLogCategory
        fileprivate let name: StaticString
        fileprivate let id: OSSignpostID
    }

    /// Subsystem identifier for the system logger (appears in Console.app)
    private static let subsystem = "com.mirage"

    /// Cached system logger instances per category (created lazily)
    private static let loggers: [MirageLogCategory: Logger] = {
        var result: [MirageLogCategory: Logger] = [:]
        for category in MirageLogCategory.allCases {
            result[category] = Logger(subsystem: subsystem, category: category.rawValue)
        }
        return result
    }()

    /// Cached OSLog instances used for signposts.
    private static let signpostLogs: [MirageLogCategory: OSLog] = {
        var result: [MirageLogCategory: OSLog] = [:]
        for category in MirageLogCategory.allCases {
            result[category] = OSLog(subsystem: subsystem, category: category.rawValue)
        }
        return result
    }()

    /// Enabled log categories (evaluated once at startup from env var)
    public static let enabledCategories: Set<MirageLogCategory> = parseEnvironment()

    /// Check if a category is enabled
    public static func isEnabled(_ category: MirageLogCategory) -> Bool {
        enabledCategories.contains(category)
    }

    /// Log a message if the category is enabled
    /// Uses @autoclosure to avoid string interpolation when logging is disabled
    public static func log(
        _ category: MirageLogCategory,
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
        _ category: MirageLogCategory,
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
        _ category: MirageLogCategory,
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
        _ category: MirageLogCategory,
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
                let metadata = LoomDiagnosticsErrorMetadata(error: error)
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
        _ category: MirageLogCategory,
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
        _ category: MirageLogCategory,
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
                let metadata = LoomDiagnosticsErrorMetadata(error: error)
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
        _ category: MirageLogCategory,
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
        _ category: MirageLogCategory,
        level: LoomLogLevel,
        message: () -> String,
        fileID: String,
        line: UInt,
        function: String,
        underlyingError: Error? = nil,
        errorSource: LoomDiagnosticsErrorSource = .logger
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
        LoomDiagnostics.record(log: LoomDiagnosticsLogEvent(
            date: now,
            category: LoomLogCategory(rawValue: category.rawValue),
            level: level,
            message: sourceMessage,
            fileID: fileID,
            line: line,
            function: function
        ))

        switch level {
        case .error,
             .fault:
            LoomDiagnostics.record(error: LoomDiagnosticsErrorEvent(
                date: now,
                category: LoomLogCategory(rawValue: category.rawValue),
                severity: level == .fault ? .fault : .error,
                source: errorSource,
                message: sourceMessage,
                fileID: fileID,
                line: line,
                function: function,
                metadata: underlyingError.map(LoomDiagnosticsErrorMetadata.init(error:))
            ))
        case .info,
             .debug:
            break
        }
    }

    private static func sourcePrefix(fileID: String, line: UInt, function: String) -> String {
        "[\(fileID):\(line) \(function)]"
    }

    private static func logger(for category: MirageLogCategory) -> Logger {
        loggers[category] ?? Logger(subsystem: subsystem, category: category.rawValue)
    }

    private static func signpostLog(for category: MirageLogCategory) -> OSLog {
        signpostLogs[category] ?? OSLog(subsystem: subsystem, category: category.rawValue)
    }

    private static func signpostMessage(
        _ message: @autoclosure () -> String,
        fileID: String,
        line: UInt,
        function: String
    ) -> String {
        let rawMessage = message()
        guard !rawMessage.isEmpty else {
            return sourcePrefix(fileID: fileID, line: line, function: function)
        }
        return "\(sourcePrefix(fileID: fileID, line: line, function: function)) \(rawMessage)"
    }

    public static func signpostEvent(
        _ category: MirageLogCategory,
        _ name: StaticString,
        _ message: @autoclosure () -> String = "",
        fileID: String = #fileID,
        line: UInt = #line,
        function: String = #function
    ) {
        guard enabledCategories.contains(category) else { return }
        let formattedMessage = signpostMessage(
            message(),
            fileID: fileID,
            line: line,
            function: function
        )
        os_signpost(
            .event,
            log: signpostLog(for: category),
            name: name,
            "%{public}s",
            formattedMessage
        )
    }

    public static func beginInterval(
        _ category: MirageLogCategory,
        _ name: StaticString,
        _ message: @autoclosure () -> String = "",
        fileID: String = #fileID,
        line: UInt = #line,
        function: String = #function
    ) -> SignpostInterval {
        let interval = SignpostInterval(
            category: category,
            name: name,
            id: OSSignpostID(log: signpostLog(for: category))
        )

        guard enabledCategories.contains(category) else { return interval }
        let formattedMessage = signpostMessage(
            message(),
            fileID: fileID,
            line: line,
            function: function
        )
        os_signpost(
            .begin,
            log: signpostLog(for: category),
            name: name,
            signpostID: interval.id,
            "%{public}s",
            formattedMessage
        )
        return interval
    }

    public static func endInterval(
        _ interval: SignpostInterval?,
        _ message: @autoclosure () -> String = "",
        fileID: String = #fileID,
        line: UInt = #line,
        function: String = #function
    ) {
        guard let interval else { return }
        guard enabledCategories.contains(interval.category) else { return }
        let formattedMessage = signpostMessage(
            message(),
            fileID: fileID,
            line: line,
            function: function
        )
        os_signpost(
            .end,
            log: signpostLog(for: interval.category),
            name: interval.name,
            signpostID: interval.id,
            "%{public}s",
            formattedMessage
        )
    }

    public static func withInterval<T>(
        _ category: MirageLogCategory,
        _ name: StaticString,
        _ message: @autoclosure () -> String = "",
        fileID: String = #fileID,
        line: UInt = #line,
        function: String = #function,
        operation: () throws -> T
    ) rethrows -> T {
        let interval = beginInterval(
            category,
            name,
            message(),
            fileID: fileID,
            line: line,
            function: function
        )
        defer {
            endInterval(
                interval,
                fileID: fileID,
                line: line,
                function: function
            )
        }
        return try operation()
    }

    public static func withInterval<T>(
        _ category: MirageLogCategory,
        _ name: StaticString,
        _ message: @autoclosure () -> String = "",
        fileID: String = #fileID,
        line: UInt = #line,
        function: String = #function,
        operation: () async throws -> T
    ) async rethrows -> T {
        let interval = beginInterval(
            category,
            name,
            message(),
            fileID: fileID,
            line: line,
            function: function
        )
        defer {
            endInterval(
                interval,
                fileID: fileID,
                line: line,
                function: function
            )
        }
        return try await operation()
    }

    /// Parse MIRAGE_LOG environment variable
    private static func parseEnvironment() -> Set<MirageLogCategory> {
        guard let envValue = ProcessInfo.processInfo.environment["MIRAGE_LOG"] else {
            // Default: essential connection + client render/decode lifecycle logs
            return [.host, .client, .appState, .stream, .decoder, .renderer]
        }

        let trimmed = envValue.trimmingCharacters(in: .whitespaces).lowercased()

        switch trimmed {
        case "all":
            return Set(MirageLogCategory.allCases)
        case "",
             "none":
            return []
        default:
            // Parse comma-separated list
            let names = trimmed.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            var categories: Set<MirageLogCategory> = []
            for name in names {
                if let category = MirageLogCategory(rawValue: name) { categories.insert(category) }
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
