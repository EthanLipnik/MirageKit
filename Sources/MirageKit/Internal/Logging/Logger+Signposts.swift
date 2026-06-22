//
//  Logger+Signposts.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/13/26.
//

import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageMedia
import MirageWire
import os

public extension MirageLogger {
    /// Emit a one-shot signpost event for a category when that category is enabled.
    static func signpostEvent(
        _ category: MirageDiagnostics.MirageLogCategory,
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

    /// Begin a signpost interval and return the token required to close it.
    static func beginInterval(
        _ category: MirageDiagnostics.MirageLogCategory,
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

    /// End a previously opened signpost interval.
    static func endInterval(
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

    /// Wrap synchronous work in a signpost interval.
    static func withInterval<T>(
        _ category: MirageDiagnostics.MirageLogCategory,
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

    /// Wrap asynchronous work in a signpost interval.
    static func withInterval<T>(
        _ category: MirageDiagnostics.MirageLogCategory,
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

    private static func signpostLog(for category: MirageDiagnostics.MirageLogCategory) -> OSLog {
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
}
