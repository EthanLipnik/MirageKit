//
//  ApplicationScannerSelectionTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/26/26.
//
//  App-scanner duplicate selection policy tests.
//

@testable import MirageKitHost
import Testing

#if os(macOS)
@Suite("Application Scanner Duplicate Selection")
struct ApplicationScannerSelectionTests {
    @Test("Running app copy is preferred over default copy")
    func runningCopyPreferredOverDefaultCopy() {
        let candidatePath = "/Applications/Xcode-beta.app"
        let existingPath = "/Applications/Xcode.app"

        let preferred = ApplicationScanner.runtimePathPreference(
            candidatePath: candidatePath,
            existingPath: existingPath,
            runningPaths: [candidatePath],
            defaultPath: existingPath
        )

        #expect(preferred == true)
    }

    @Test("Default app copy is preferred when no copy is running")
    func defaultCopyPreferredWhenNoCopyRunning() {
        let candidatePath = "/Applications/Xcode-beta.app"
        let existingPath = "/Applications/Xcode.app"

        let preferred = ApplicationScanner.runtimePathPreference(
            candidatePath: candidatePath,
            existingPath: existingPath,
            runningPaths: [],
            defaultPath: candidatePath
        )

        #expect(preferred == true)
    }

    @Test("Runtime preference returns nil when no tie breaker applies")
    func runtimePreferenceReturnsNilWithoutTieBreaker() {
        let candidatePath = "/Applications/Xcode-beta.app"
        let existingPath = "/Applications/Xcode.app"

        let preferred = ApplicationScanner.runtimePathPreference(
            candidatePath: candidatePath,
            existingPath: existingPath,
            runningPaths: [],
            defaultPath: nil
        )

        #expect(preferred == nil)
    }
}
#endif
