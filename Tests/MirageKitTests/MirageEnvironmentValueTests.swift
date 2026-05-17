//
//  MirageEnvironmentValueTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/9/26.
//

@testable import MirageKit
import Foundation
import Testing

@Suite("Mirage environment values")
struct MirageEnvironmentValueTests {
    @Test
    func normalizedTokenTrimsAndSplitsValues() {
        #expect(MirageEnvironmentValue.normalizedToken(nil) == nil)
        #expect(MirageEnvironmentValue.normalizedToken("") == nil)
        #expect(MirageEnvironmentValue.normalizedToken("  TRUE;ignored  ") == "true")
        #expect(MirageEnvironmentValue.normalizedToken("  yes ignored  ") == "yes")
    }

    @Test(arguments: ["1", "true", "YES", " on "])
    func truthyValuesParseAsTrue(rawValue: String) {
        #expect(MirageEnvironmentValue.isTruthy(rawValue))
        #expect(MirageEnvironmentValue.boolean(rawValue) == true)
    }

    @Test(arguments: ["0", "false", "NO", " off ; ignored"])
    func falseyValuesParseAsFalse(rawValue: String) {
        #expect(!MirageEnvironmentValue.isTruthy(rawValue))
        #expect(MirageEnvironmentValue.boolean(rawValue) == false)
    }

    @Test
    func unknownValuesDoNotParseAsBooleans() {
        #expect(!MirageEnvironmentValue.isTruthy("enabled"))
        #expect(MirageEnvironmentValue.boolean("enabled") == nil)
        #expect(MirageEnvironmentValue.boolean(nil) == nil)
    }

    @Test
    func mirageLogAllEnablesEveryCategory() {
        #expect(MirageLogger.parsedEnabledCategories(environmentValue: "all") == Set(MirageLogCategory.allCases))
        #expect(MirageLogger.parsedEnabledCategories(environmentValue: " client, all ") == Set(MirageLogCategory.allCases))
        #expect(MirageLogger.fullVerboseLoggingRequested(environmentValue: " metrics;all ") == true)
    }

    @Test
    func mirageLogCategoryParsingIsCaseAndSeparatorInsensitive() {
        let categories = MirageLogger.parsedEnabledCategories(
            environmentValue: "appState, window-filter bootstrap_handoff"
        )

        #expect(categories == Set([MirageLogCategory.appState, .windowFilter, .bootstrapHandoff]))
    }

    @Test
    func mirageLogAllEnablesLatencyDiagnostics() {
        let suiteName = "MirageEnvironmentValueTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(MirageLatencyOptions.latencyDiagnosticsEnabled(
            environment: ["MIRAGE_LOG": "all"],
            defaults: defaults
        ))
        #expect(!MirageLatencyOptions.latencyDiagnosticsEnabled(
            environment: ["MIRAGE_LOG": "client"],
            defaults: defaults
        ))
    }
}
