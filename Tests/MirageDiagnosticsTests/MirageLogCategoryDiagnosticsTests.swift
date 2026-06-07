//
//  MirageLogCategoryDiagnosticsTests.swift
//  MirageDiagnostics
//
//  Created by Ethan Lipnik on 6/5/26.
//

import MirageDiagnostics
import Testing

@Suite("Mirage Log Category Diagnostics")
struct MirageLogCategoryDiagnosticsTests {
    @Test("Log categories preserve stable raw names")
    func logCategoriesPreserveStableRawNames() {
        #expect(MirageDiagnostics.MirageLogCategory.timing.rawValue == "timing")
        #expect(MirageDiagnostics.MirageLogCategory.appState.rawValue == "appState")
        #expect(MirageDiagnostics.MirageLogCategory.windowFilter.rawValue == "windowFilter")
        #expect(MirageDiagnostics.MirageLogCategory.frameAssembly.rawValue == "frameAssembly")
        #expect(MirageDiagnostics.MirageLogCategory.windowActivator.rawValue == "windowActivator")
        #expect(MirageDiagnostics.MirageLogCategory.bootstrapHandoff.rawValue == "bootstrap_handoff")
    }

    @Test("Log category cases remain available for support filtering")
    func logCategoryCasesRemainAvailableForSupportFiltering() {
        #expect(MirageDiagnostics.MirageLogCategory.allCases.count == 21)
        #expect(Set(MirageDiagnostics.MirageLogCategory.allCases).contains(.client))
        #expect(Set(MirageDiagnostics.MirageLogCategory.allCases).contains(.host))
        #expect(Set(MirageDiagnostics.MirageLogCategory.allCases).contains(.stream))
        #expect(Set(MirageDiagnostics.MirageLogCategory.allCases).contains(.bootstrapHandoff))
    }
}
