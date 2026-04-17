//
//  MirageLoggerEnvironmentParsingTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/15/26.
//

@testable import MirageKit
import Loom
import Testing

@Suite("Mirage Logger Environment Parsing")
struct MirageLoggerEnvironmentParsingTests {
    @Test("Unset environment enables only essential categories")
    func unsetEnvironmentEnablesOnlyEssentialCategories() {
        #expect(
            MirageLogger.parsedEnabledCategories(environmentValue: nil) ==
                [.host, .client, .appState, .stream, .decoder, .renderer]
        )
    }

    @Test("Unset environment keeps client support log baseline categories emitted")
    func unsetEnvironmentKeepsClientSupportLogBaselineCategoriesEmitted() {
        let enabledCategories = Set(
            MirageLogger
                .parsedEnabledCategories(environmentValue: nil)
                .map { LoomLogCategory(rawValue: $0.rawValue) }
        )
        #expect(MirageLogRecorder.Configuration.client.baselineCategories.allSatisfy { category in
            enabledCategories.contains(category)
        })
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
