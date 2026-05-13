//
//  MirageEnvironmentValueTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/9/26.
//

@testable import MirageKit
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
}
