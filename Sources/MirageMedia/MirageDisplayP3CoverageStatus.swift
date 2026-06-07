//
//  MirageDisplayP3CoverageStatus.swift
//  MirageMedia
//
//  Created by Ethan Lipnik on 3/4/26.
//

/// Result of validating whether a virtual display can represent Display P3 correctly.
public enum MirageDisplayP3CoverageStatus: String, Codable, Sendable, CaseIterable {
    /// Display P3 is available through the canonical expected display mode.
    case strictCanonical
    /// A wide-gamut mode is available but does not match the canonical Display P3 path.
    case wideGamutEquivalent
    /// Only sRGB coverage is available.
    case sRGBFallback
    /// Display gamut coverage could not be resolved.
    case unresolved

    /// User-facing label for color validation summaries.
    public var displayName: String {
        switch self {
        case .strictCanonical:
            "Display P3"
        case .wideGamutEquivalent:
            "Wide Gamut Equivalent"
        case .sRGBFallback:
            "sRGB Fallback"
        case .unresolved:
            "Unresolved"
        }
    }

    /// Whether callers should warn that canonical Display P3 coverage is unavailable.
    public var requiresCanonicalCoverageWarning: Bool {
        self == .sRGBFallback || self == .unresolved
    }
}
