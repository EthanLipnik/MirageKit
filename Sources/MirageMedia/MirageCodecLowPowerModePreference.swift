//
//  MirageCodecLowPowerModePreference.swift
//  MirageMedia
//
//  Created by Ethan Lipnik on 3/5/26.
//

/// Low-power preference for local codec sessions.
///
/// This preference is evaluated locally on each device:
/// - host setting controls the host encoder
/// - client setting controls the client decoder
public enum MirageCodecLowPowerModePreference: String, Sendable, Codable, CaseIterable, Identifiable {
    /// Follow the platform low-power state when the device exposes one.
    case auto

    /// Force VideoToolbox low-power mode whenever the codec supports it.
    case on

    /// Enable low-power mode only while the device is running on battery.
    case onlyOnBattery

    /// Stable identity for SwiftUI controls and persisted selections.
    public var id: String { rawValue }

    /// Human-readable label for settings controls.
    public var displayName: String {
        switch self {
        case .auto:
            "Auto"
        case .on:
            "Always"
        case .onlyOnBattery:
            "On Battery"
        }
    }

    /// Settings options valid for the current platform's battery-state support.
    public static func availableOptions(
        supportsBatteryPolicy: Bool
    ) -> [MirageCodecLowPowerModePreference] {
        if supportsBatteryPolicy {
            return allCases
        }
        return allCases.filter { $0 != .onlyOnBattery }
    }

    /// Falls back to `.auto` when the current platform cannot report battery status.
    public func resolvedForBatteryPolicySupport(
        _ supportsBatteryPolicy: Bool
    ) -> MirageCodecLowPowerModePreference {
        if self == .onlyOnBattery, !supportsBatteryPolicy {
            return .auto
        }
        return self
    }

    /// Resolves this preference into the boolean VideoToolbox low-power flag.
    public func resolvesToLowPowerMode(
        isSystemLowPowerModeEnabled: Bool,
        isOnBattery: Bool?
    ) -> Bool {
        switch self {
        case .auto:
            isSystemLowPowerModeEnabled
        case .on:
            true
        case .onlyOnBattery:
            isOnBattery == true
        }
    }
}
