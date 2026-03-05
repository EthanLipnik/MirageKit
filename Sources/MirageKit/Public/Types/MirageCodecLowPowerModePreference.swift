//
//  MirageCodecLowPowerModePreference.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/5/26.
//

import Foundation

/// Low-power preference for local codec sessions.
///
/// This preference is evaluated locally on each device:
/// - host setting controls the host encoder
/// - client setting controls the client decoder
public enum MirageCodecLowPowerModePreference: String, Sendable, Codable, CaseIterable, Identifiable {
    case auto
    case on
    case onlyOnBattery

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .auto:
            "Auto"
        case .on:
            "On"
        case .onlyOnBattery:
            "Only on Battery"
        }
    }

    public func resolvedForBatteryPolicySupport(
        _ supportsBatteryPolicy: Bool
    ) -> MirageCodecLowPowerModePreference {
        if self == .onlyOnBattery, !supportsBatteryPolicy {
            return .auto
        }
        return self
    }

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
