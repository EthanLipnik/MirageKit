//
//  MirageAppPreferencesTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/10/26.
//

@testable import MirageKitClient
import Foundation
import Testing

@Suite("Client App Preferences")
struct MirageAppPreferencesTests {
    @Test("Pinned-only filter persists independently per host")
    func pinnedOnlyFilterPersistsIndependentlyPerHost() {
        let hostA = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let hostB = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

        var preferences = MirageAppPreferences()
        preferences.setShowPinnedOnlyApps(true, for: hostA)
        preferences.setShowPinnedOnlyApps(false, for: hostB)

        #expect(preferences.showsPinnedOnlyApps(for: hostA))
        #expect(!preferences.showsPinnedOnlyApps(for: hostB))
    }

    @Test("Legacy host preference payloads decode without the pinned-only flag")
    func legacyHostPreferencePayloadsDecodeWithoutPinnedOnlyFlag() throws {
        let hostID = "11111111-1111-1111-1111-111111111111"
        let payload = """
        {
            "hostPreferences": {
                "\(hostID)": {
                    "pinnedApps": [
                        "com.apple.Safari"
                    ],
                    "showNonStandardApps": true
                }
            }
        }
        """

        let preferences = try JSONDecoder().decode(
            MirageAppPreferences.self,
            from: Data(payload.utf8)
        )

        #expect(preferences.preferences(for: UUID(uuidString: hostID)!).showNonStandardApps)
        #expect(!preferences.preferences(for: UUID(uuidString: hostID)!).showPinnedOnlyApps)
    }
}
