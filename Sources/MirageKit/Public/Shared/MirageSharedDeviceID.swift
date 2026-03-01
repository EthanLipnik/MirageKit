//
//  MirageSharedDeviceID.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/28/26.
//
//  Shared App Group-backed device identifier used by Mirage host/client apps.
//

import Foundation

/// Provides a stable device identifier shared between Mirage host and client apps.
///
/// Uses App Groups to share a single UUID between both apps so the client can
/// filter out its own host from discovered hosts.
public enum MirageSharedDeviceID {
    /// App Group suite name for shared UserDefaults.
    public static let suiteName = "group.com.ethanlipnik.Mirage"

    /// UserDefaults key for the shared device ID.
    public static let key = "com.mirage.shared.deviceID"

    /// Returns the shared device ID, creating one if needed.
    ///
    /// Priority:
    /// 1. Existing ID in shared App Group suite
    /// 2. Migration from old per-app keys
    /// 3. Create new ID
    public static func getOrCreate() -> UUID {
        if let sharedDefaults = UserDefaults(suiteName: suiteName),
           let stored = sharedDefaults.string(forKey: key),
           let uuid = UUID(uuidString: stored) {
            return uuid
        }

        let oldKeys = ["com.mirage.client.deviceID", "com.mirage.cloudkit.deviceID"]
        for oldKey in oldKeys {
            if let old = UserDefaults.standard.string(forKey: oldKey),
               let uuid = UUID(uuidString: old) {
                UserDefaults(suiteName: suiteName)?.set(uuid.uuidString, forKey: key)
                return uuid
            }
        }

        let newID = UUID()
        UserDefaults(suiteName: suiteName)?.set(newID.uuidString, forKey: key)
        return newID
    }
}
