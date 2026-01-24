//
//  MirageTrustStore.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/21/26.
//

import Foundation
import Observation

/// Trusted device record used by Mirage trust store.
public struct MirageTrustedDevice: Identifiable, Codable, Equatable {
    public let id: UUID
    public let name: String
    public let deviceType: DeviceType
    public let trustedAt: Date

    public init(id: UUID, name: String, deviceType: DeviceType, trustedAt: Date) {
        self.id = id
        self.name = name
        self.deviceType = deviceType
        self.trustedAt = trustedAt
    }
}

/// Stores trusted devices with persistence to UserDefaults.
@Observable
@MainActor
public final class MirageTrustStore {
    /// Trusted devices (persisted to UserDefaults).
    public private(set) var trustedDevices: [MirageTrustedDevice] = []

    /// Flag to prevent saving during load.
    private var isLoading = false

    /// UserDefaults key for trusted devices.
    private let trustedDevicesKey: String

    /// Creates a trust store with a configurable storage key.
    /// - Parameter storageKey: UserDefaults key used for persistence.
    public init(storageKey: String = "MirageTrustedDevices") {
        self.trustedDevicesKey = storageKey
        loadTrustedDevices()
    }

    // MARK: - Persistence

    /// Load trusted devices from storage.
    public func loadTrustedDevices() {
        guard let data = UserDefaults.standard.data(forKey: trustedDevicesKey) else {
            return
        }
        do {
            isLoading = true
            trustedDevices = try JSONDecoder().decode([MirageTrustedDevice].self, from: data)
            isLoading = false
            MirageLogger.appState("Loaded \(trustedDevices.count) trusted devices")
        } catch {
            isLoading = false
            MirageLogger.error(.appState, "Failed to load trusted devices: \(error)")
        }
    }

    private func saveTrustedDevices() {
        guard !isLoading else { return }
        do {
            let data = try JSONEncoder().encode(trustedDevices)
            UserDefaults.standard.set(data, forKey: trustedDevicesKey)
            MirageLogger.appState("Saved \(trustedDevices.count) trusted devices")
        } catch {
            MirageLogger.error(.appState, "Failed to save trusted devices: \(error)")
        }
    }

    // MARK: - Trust Operations

    /// Returns whether the provided device ID is trusted.
    /// - Parameter deviceID: The device identifier to check.
    public func isTrusted(deviceID: UUID) -> Bool {
        trustedDevices.contains { $0.id == deviceID }
    }

    /// Add a trusted device and persist it.
    /// - Parameter device: Trusted device to add.
    public func addTrustedDevice(_ device: MirageTrustedDevice) {
        trustedDevices.append(device)
        saveTrustedDevices()
    }

    /// Remove a trusted device and persist the update.
    /// - Parameter device: Trusted device to revoke.
    public func revokeTrust(for device: MirageTrustedDevice) {
        trustedDevices.removeAll { $0.id == device.id }
        saveTrustedDevices()
    }
}
