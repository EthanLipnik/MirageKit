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
        let category: MirageLogCategory
        let name: StaticString
        let id: OSSignpostID
    }

    /// Subsystem identifier for the system logger (appears in Console.app)
    static let subsystem = "com.mirage"

    /// Cached system logger instances per category (created lazily)
    private static let loggers: [MirageLogCategory: Logger] = {
        var result: [MirageLogCategory: Logger] = [:]
        for category in MirageLogCategory.allCases {
            result[category] = Logger(subsystem: subsystem, category: category.rawValue)
        }
        return result
    }()

    /// Cached OSLog instances used for signposts.
    static let signpostLogs: [MirageLogCategory: OSLog] = {
        var result: [MirageLogCategory: OSLog] = [:]
        for category in MirageLogCategory.allCases {
            result[category] = OSLog(subsystem: subsystem, category: category.rawValue)
        }
        return result
    }()

    /// Enabled log categories (evaluated once at startup from env var)
    public static let enabledCategories: Set<MirageLogCategory> = parsedEnabledCategories(
        environmentValue: ProcessInfo.processInfo.environment["MIRAGE_LOG"]
    )

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

    static func logInfo(
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
        let logger = loggers[category] ?? Logger(subsystem: subsystem, category: category.rawValue)
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

    static func sourcePrefix(fileID: String, line: UInt, function: String) -> String {
        "[\(fileID):\(line) \(function)]"
    }

    /// Parse MIRAGE_LOG environment variable.
    static func parsedEnabledCategories(environmentValue: String?) -> Set<MirageLogCategory> {
        guard let environmentValue else {
            return [.host, .client, .appState, .stream, .decoder, .renderer]
        }

        let tokens = logTokens(from: environmentValue)
        guard !tokens.isEmpty else { return [] }
        guard !tokens.contains("none") else { return [] }
        if tokens.contains("all") {
            return Set(MirageLogCategory.allCases)
        }

        var categories: Set<MirageLogCategory> = []
        for token in tokens {
            guard let category = MirageLogCategory.matchingLogToken(token) else { continue }
            categories.insert(category)
        }
        return categories
    }

    static func fullVerboseLoggingRequested(environmentValue: String?) -> Bool {
        let tokens = logTokens(from: environmentValue)
        return tokens.contains("all") && !tokens.contains("none")
    }

    private static func logTokens(from environmentValue: String?) -> [String] {
        guard let environmentValue else { return [] }
        return environmentValue
            .split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == ";" })
            .map { normalizeLogToken(String($0)) }
            .filter { !$0.isEmpty }
    }

    private static func normalizeLogToken(_ token: String) -> String {
        token
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .filter { $0 != "_" && $0 != "-" }
    }
}

private extension MirageLogCategory {
    static func matchingLogToken(_ token: String) -> MirageLogCategory? {
        allCases.first { category in
            MirageLogger.normalizeLogCategoryName(category.rawValue) == token
        }
    }
}

private extension MirageLogger {
    static func normalizeLogCategoryName(_ name: String) -> String {
        name.lowercased().filter { $0 != "_" && $0 != "-" }
    }
}
