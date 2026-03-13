//
//  ClientDeviceIDPersistenceTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/13/26.
//

@testable import MirageKit
@testable import MirageKitClient
import Foundation
import Testing

@Suite("Client Device ID Persistence", .serialized)
struct ClientDeviceIDPersistenceTests {
    @MainActor
    @Test("Client service ignores deprecated device ID keys and creates a fresh shared ID")
    func clientServiceIgnoresDeprecatedDeviceIDKeysAndCreatesFreshSharedID() {
        let suiteName = MirageKit.sharedDeviceIDSuiteName
        let suiteDefaults = UserDefaults(suiteName: suiteName)!
        let standardDefaults = UserDefaults.standard
        let originalSuiteDomain = standardDefaults.persistentDomain(forName: suiteName)
        let legacyKeys = [
            "com.mirage.client.deviceID",
            "com.mirage.cloudkit.deviceID",
            LoomSharedDeviceID.key,
        ]
        let originalStandardValues = legacyKeys.reduce(into: [String: Any?]()) { values, key in
            values[key] = standardDefaults.object(forKey: key)
        }

        defer {
            if let originalSuiteDomain {
                standardDefaults.setPersistentDomain(originalSuiteDomain, forName: suiteName)
            } else {
                standardDefaults.removePersistentDomain(forName: suiteName)
            }

            for (key, value) in originalStandardValues {
                if let value {
                    standardDefaults.set(value, forKey: key)
                } else {
                    standardDefaults.removeObject(forKey: key)
                }
            }
        }

        standardDefaults.removePersistentDomain(forName: suiteName)
        for key in legacyKeys {
            standardDefaults.removeObject(forKey: key)
            suiteDefaults.removeObject(forKey: key)
        }

        let legacyDeviceID = UUID()
        standardDefaults.set(legacyDeviceID.uuidString, forKey: "com.mirage.client.deviceID")

        let service = MirageClientService(deviceName: "Regression Device")

        #expect(service.deviceID != legacyDeviceID)
        #expect(
            suiteDefaults.string(forKey: MirageKit.sharedDeviceIDKey) == service.deviceID.uuidString
        )
        #expect(standardDefaults.string(forKey: "com.mirage.client.deviceID") == nil)
    }
}
