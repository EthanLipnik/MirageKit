//
//  MirageDisplayP3CoverageStatus.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/4/26.
//

import Foundation

public enum MirageDisplayP3CoverageStatus: String, Codable, Sendable, CaseIterable {
    case strictCanonical
    case wideGamutEquivalent
    case sRGBFallback
    case unresolved

    public var achievedCanonicalDisplayP3: Bool {
        self == .strictCanonical
    }

    public var requiresCanonicalCoverageWarning: Bool {
        self == .sRGBFallback || self == .unresolved
    }
}
