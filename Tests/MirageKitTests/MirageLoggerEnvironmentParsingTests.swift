//
//  MirageLoggerEnvironmentParsingTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/15/26.
//

@testable import MirageKit
import Testing

@Suite("Mirage Logger Environment Parsing")
struct MirageLoggerEnvironmentParsingTests {
    @Test("Unset environment enables only essential categories")
    func unsetEnvironmentEnablesOnlyEssentialCategories() {
        #expect(
            MirageLogger.parsedEnabledCategories(environmentValue: nil) ==
                [.host, .client, .appState]
        )
    }

    @Test("None disables all non-error categories")
    func noneDisablesAllCategories() {
        #expect(MirageLogger.parsedEnabledCategories(environmentValue: "none").isEmpty)
        #expect(MirageLogger.parsedEnabledCategories(environmentValue: "").isEmpty)
    }

    @Test("All enables every known category")
    func allEnablesEveryKnownCategory() {
        #expect(
            MirageLogger.parsedEnabledCategories(environmentValue: "all") ==
                Set(MirageLogCategory.allCases)
        )
    }

    @Test("Comma-separated categories are parsed case-insensitively")
    func commaSeparatedCategoriesAreParsedCaseInsensitively() {
        #expect(
            MirageLogger.parsedEnabledCategories(environmentValue: " Metrics, network ,CLIENT ") ==
                [.metrics, .network, .client]
        )
    }
}
