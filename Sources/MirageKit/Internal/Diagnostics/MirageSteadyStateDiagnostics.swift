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
        MirageEnvironmentValue.isTruthy(environment["MIRAGE_STEADY_STATE_DIAGNOSTICS"]) ||
            MirageEnvironmentValue.isTruthy(environment["MIRAGE_STREAMING_VERBOSE_DIAGNOSTICS"])
    }
}
