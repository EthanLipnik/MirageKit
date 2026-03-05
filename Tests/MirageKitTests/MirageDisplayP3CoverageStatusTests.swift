//
//  MirageDisplayP3CoverageStatusTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/5/26.
//

@testable import MirageKit
import Testing

@Suite("Display P3 Coverage Status")
struct MirageDisplayP3CoverageStatusTests {
    @Test("Wide-gamut equivalent does not require canonical warning")
    func wideGamutEquivalentDoesNotWarn() {
        #expect(MirageDisplayP3CoverageStatus.wideGamutEquivalent.requiresCanonicalCoverageWarning == false)
    }

    @Test("sRGB fallback and unresolved require canonical warning")
    func fallbackAndUnresolvedRequireWarning() {
        #expect(MirageDisplayP3CoverageStatus.sRGBFallback.requiresCanonicalCoverageWarning == true)
        #expect(MirageDisplayP3CoverageStatus.unresolved.requiresCanonicalCoverageWarning == true)
    }
}
