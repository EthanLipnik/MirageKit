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

public struct MirageLogEntry: Sendable {
    public let date: Date
    public let category: LogCategory
    public let level: MirageLogLevel
    public let message: String
}

public protocol MirageLogSink: Sendable {
    func record(_ entry: MirageLogEntry) async
}

actor MirageLogSinkStore {
    static let shared = MirageLogSinkStore()
    private var sink: MirageLogSink?

    func setSink(_ sink: MirageLogSink?) {
        self.sink = sink
    }

    func record(_ entry: MirageLogEntry) async {
        await sink?.record(entry)
    }
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
}

/// Centralized logging for Mirage using Apple's unified logging system (os.Logger)
///
/// Logs appear in Console.app under the "com.mirage" subsystem, filtered by category.
///
/// Set `MIRAGE_LOG` environment variable in Xcode scheme:
/// - `all` - Enable all log categories
/// - `none` - Disable all logging (except errors)
/// - `metrics,timing,encoder` - Enable specific categories (comma-separated)
/// - Not set - Default: essential logs only (host, client, appState)
public struct MirageLogger: Sendable {
    /// Subsystem identifier for os.Logger (appears in Console.app)
    private static let subsystem = "com.mirage"

    /// Cached os.Logger instances per category (created lazily)
    private static let loggers: [LogCategory: os.Logger] = {
        var result: [LogCategory: os.Logger] = [:]
        for category in LogCategory.allCases {
            result[category] = os.Logger(subsystem: subsystem, category: category.rawValue)
        }
        return result
    }()

    /// Enabled log categories (evaluated once at startup from env var)
    public static let enabledCategories: Set<LogCategory> = parseEnvironment()

    public static func setLogSink(_ sink: MirageLogSink?) {
        Task {
            await MirageLogSinkStore.shared.setSink(sink)
        }
    }

    /// Check if a category is enabled
    public static func isEnabled(_ category: LogCategory) -> Bool {
        enabledCategories.contains(category)
    }

    /// Log a message if the category is enabled
    /// Uses @autoclosure to avoid string interpolation when logging is disabled
    public static func log(_ category: LogCategory, _ message: @autoclosure () -> String) {
        guard enabledCategories.contains(category) else { return }
        let msg = message()
        loggers[category]?.info("\(msg, privacy: .public)")
        record(category: category, level: .info, message: msg)
    }

    /// Log a debug-level message (lower priority, filtered by default in Console.app)
    public static func debug(_ category: LogCategory, _ message: @autoclosure () -> String) {
        guard enabledCategories.contains(category) else { return }
        let msg = message()
        loggers[category]?.debug("\(msg, privacy: .public)")
        record(category: category, level: .debug, message: msg)
    }

    /// Log a message unconditionally (for errors)
    /// Errors are always logged regardless of category enablement
    public static func error(_ category: LogCategory, _ message: @autoclosure () -> String) {
        let msg = message()
        loggers[category]?.error("\(msg, privacy: .public)")
        record(category: category, level: .error, message: msg)
    }

    /// Log a fault-level message (critical errors that indicate bugs)
    public static func fault(_ category: LogCategory, _ message: @autoclosure () -> String) {
        let msg = message()
        loggers[category]?.fault("\(msg, privacy: .public)")
        record(category: category, level: .fault, message: msg)
    }

    private static func record(category: LogCategory, level: MirageLogLevel, message: String) {
        if Task.isCancelled { return }
        Task {
            await MirageLogSinkStore.shared.record(MirageLogEntry(
                date: Date(),
                category: category,
                level: level,
                message: message
            ))
        }
    }

    /// Parse MIRAGE_LOG environment variable
    private static func parseEnvironment() -> Set<LogCategory> {
        guard let envValue = ProcessInfo.processInfo.environment["MIRAGE_LOG"] else {
            // Default: essential logs only
            return [.host, .client, .appState]
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
    static func timing(_ message: @autoclosure () -> String) {
        log(.timing, message())
    }

    /// Log pipeline throughput metrics
    static func metrics(_ message: @autoclosure () -> String) {
        log(.metrics, message())
    }

    /// Log capture engine events
    static func capture(_ message: @autoclosure () -> String) {
        log(.capture, message())
    }

    /// Log encoder events
    static func encoder(_ message: @autoclosure () -> String) {
        log(.encoder, message())
    }

    /// Log decoder events
    static func decoder(_ message: @autoclosure () -> String) {
        log(.decoder, message())
    }

    /// Log client events
    static func client(_ message: @autoclosure () -> String) {
        log(.client, message())
    }

    /// Log host events
    static func host(_ message: @autoclosure () -> String) {
        log(.host, message())
    }

    /// Log app state events
    static func appState(_ message: @autoclosure () -> String) {
        log(.appState, message())
    }

    /// Log renderer events
    static func renderer(_ message: @autoclosure () -> String) {
        log(.renderer, message())
    }

    /// Log stream lifecycle events
    static func stream(_ message: @autoclosure () -> String) {
        log(.stream, message())
    }

    /// Log discovery events
    static func discovery(_ message: @autoclosure () -> String) {
        log(.discovery, message())
    }

    /// Log network events
    static func network(_ message: @autoclosure () -> String) {
        log(.network, message())
    }

    /// Log menu bar passthrough events
    static func menuBar(_ message: @autoclosure () -> String) {
        log(.menuBar, message())
    }
}
