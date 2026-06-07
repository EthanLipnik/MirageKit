//
//  MirageDiagnosticsRecorder+Loom.swift
//  MirageConnectivity
//
//  Created by Ethan Lipnik on 6/5/26.
//

import Foundation
import Loom
import MirageDiagnostics

package enum MirageDiagnosticsLogLevel: Sendable {
    case info
    case debug
    case error
    case fault
}

package enum MirageDiagnosticsRecorder {
    package static func recordLog(
        date: Date,
        category: MirageDiagnostics.MirageLogCategory,
        level: MirageDiagnosticsLogLevel,
        message: String,
        fileID: String,
        line: UInt,
        function: String
    ) {
        LoomDiagnostics.record(log: LoomDiagnosticsLogEvent(
            date: date,
            category: LoomLogCategory(rawValue: category.rawValue),
            level: level.loomLevel,
            message: message,
            fileID: fileID,
            line: line,
            function: function
        ))
    }

    package static func recordLoggerError(
        date: Date,
        category: MirageDiagnostics.MirageLogCategory,
        severity: MirageDiagnostics.MirageDiagnosticsErrorSeverity,
        message: String,
        fileID: String,
        line: UInt,
        function: String,
        metadata: MirageDiagnostics.MirageDiagnosticsErrorMetadata?
    ) {
        LoomDiagnostics.record(error: LoomDiagnosticsErrorEvent(
            date: date,
            category: LoomLogCategory(rawValue: category.rawValue),
            severity: severity.loomSeverity,
            source: .logger,
            message: message,
            fileID: fileID,
            line: line,
            function: function,
            metadata: metadata?.loomMetadata
        ))
    }
}

private extension MirageDiagnosticsLogLevel {
    var loomLevel: LoomLogLevel {
        switch self {
        case .info:
            .info
        case .debug:
            .debug
        case .error:
            .error
        case .fault:
            .fault
        }
    }
}

private extension MirageDiagnostics.MirageDiagnosticsErrorSeverity {
    var loomSeverity: LoomDiagnosticsErrorSeverity {
        switch self {
        case .error:
            .error
        case .fault:
            .fault
        }
    }
}

private extension MirageDiagnostics.MirageDiagnosticsErrorMetadata {
    var loomMetadata: LoomDiagnosticsErrorMetadata {
        LoomDiagnosticsErrorMetadata(
            typeName: typeName,
            domain: domain,
            code: code
        )
    }
}
