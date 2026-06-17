//
//  MirageAdaptiveGovernorProtocol.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 6/17/26.
//

import Foundation

package enum MirageAdaptiveGovernorProtocol {
    package static let revision = 2
    package static let capabilityHostOwnedRuntime = "host-owned-runtime"
    package static let capabilityPassiveFeedback = "passive-feedback"
    package static let legacyFallbackMode = "legacy-passive-fallback"
    package static let feedbackClasses = ["hard", "soft", "diagnostic"]
}
