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
    @Test("Client service persists the shared device ID in the shared suite")
    func clientServicePersistsSharedDeviceIDInSharedSuite() {
        let suiteName = MirageKit.sharedDeviceIDSuiteName
        let suiteDefaults = UserDefaults(suiteName: suiteName)!
        let standardDefaults = UserDefaults.standard
        let originalSuiteDomain = standardDefaults.persistentDomain(forName: suiteName)
        let originalStandardValue = standardDefaults.object(forKey: LoomSharedDeviceID.key)

        defer {
            if let originalSuiteDomain {
                standardDefaults.setPersistentDomain(originalSuiteDomain, forName: suiteName)
            } else {
                standardDefaults.removePersistentDomain(forName: suiteName)
            }

            if let originalStandardValue {
                standardDefaults.set(originalStandardValue, forKey: LoomSharedDeviceID.key)
            } else {
                standardDefaults.removeObject(forKey: LoomSharedDeviceID.key)
            }
        }

        standardDefaults.removePersistentDomain(forName: suiteName)
        standardDefaults.removeObject(forKey: LoomSharedDeviceID.key)
        suiteDefaults.removeObject(forKey: LoomSharedDeviceID.key)

        let service = MirageClientService(deviceName: "Regression Device")

        #expect(
            suiteDefaults.string(forKey: MirageKit.sharedDeviceIDKey) == service.deviceID.uuidString
        )
        #expect(standardDefaults.string(forKey: LoomSharedDeviceID.key) == nil)
    }
}
