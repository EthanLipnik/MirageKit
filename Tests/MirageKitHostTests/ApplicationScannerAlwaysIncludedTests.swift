//
//  ApplicationScannerAlwaysIncludedTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 6/23/26.
//

@testable import MirageKit
@testable import MirageKitHost
import Foundation
import Testing

#if os(macOS)
@Suite("Application scanner always-included apps")
struct ApplicationScannerAlwaysIncludedTests {
    @Test("Launch Services default apps are seeded into scan candidates")
    func launchServicesDefaultAppsAreSeededIntoScanCandidates() async throws {
        let scanner = ApplicationScanner()
        var seenPaths = Set<String>()
        let runningAppPathsByBundle: [String: Set<String>] = [:]
        var defaultAppPathByBundleIdentifier: [String: String] = [:]
        var missingDefaultAppPathBundleIdentifiers = Set<String>()
        var byBundle: [String: ApplicationScanner.AppCandidate] = [:]

        await scanner.includeAlwaysIncludedApplications(
            seenPaths: &seenPaths,
            runningAppPathsByBundle: runningAppPathsByBundle,
            defaultAppPathByBundleIdentifier: &defaultAppPathByBundleIdentifier,
            missingDefaultAppPathBundleIdentifiers: &missingDefaultAppPathBundleIdentifiers,
            byBundle: &byBundle,
            onPreferredCandidate: nil
        )

        let safari = try #require(byBundle["com.apple.safari"])
        #expect(safari.bundleIdentifier?.lowercased() == "com.apple.safari")
        #expect(safari.path.hasSuffix("/Safari.app"))
    }
}
#endif
