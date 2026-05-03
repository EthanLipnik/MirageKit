//
//  MirageSteadyStateDiagnostics.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/3/26.
//

import Foundation

package enum MirageSteadyStateDiagnostics {
    package static let isEnabled = isEnabled(environment: ProcessInfo.processInfo.environment)

    package static func isEnabled(environment: [String: String]) -> Bool {
        isTruthy(environment["MIRAGE_STEADY_STATE_DIAGNOSTICS"]) ||
            isTruthy(environment["MIRAGE_STREAMING_VERBOSE_DIAGNOSTICS"])
    }

    private static func isTruthy(_ value: String?) -> Bool {
        guard let value else { return false }
        switch value.lowercased() {
        case "1", "true", "yes", "on":
            return true
        default:
            return false
        }
    }
}
