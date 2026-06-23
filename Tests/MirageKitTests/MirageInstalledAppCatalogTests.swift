//
//  MirageInstalledAppCatalogTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 6/23/26.
//

@testable import MirageKit
import Testing

@Suite("Mirage installed app catalog")
struct MirageInstalledAppCatalogTests {
    @Test("Always-included bundle identifiers are normalized")
    func alwaysIncludedBundleIdentifiersAreNormalized() {
        #expect(MirageInstalledApp.isAlwaysIncludedBundleIdentifier("com.apple.Safari"))
        #expect(MirageInstalledApp.isAlwaysIncludedBundleIdentifier("COM.APPLE.SAFARI"))
        #expect(!MirageInstalledApp.isAlwaysIncludedBundleIdentifier("com.example.Editor"))
    }
}
