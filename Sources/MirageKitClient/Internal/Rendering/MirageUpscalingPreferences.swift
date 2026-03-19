//
//  MirageUpscalingPreferences.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/18/26.
//
//  UserDefaults reader for MetalFX upscaling mode and scale factor.
//

import Foundation
import MirageKit

enum MirageUpscalingPreferences {
    private static let upscalingModeKey = "metalFXUpscalingMode"
    private static let upscaleFactorKey = "metalFXUpscaleFactor"

    static func upscalingMode() -> MirageUpscalingMode {
        guard let raw = UserDefaults.standard.string(forKey: upscalingModeKey) else {
            return .off
        }
        return MirageUpscalingMode(rawValue: raw) ?? .off
    }

    /// Returns the upscale factor (0.5–0.75). This is the fraction of the
    /// display resolution used for capture/encode. For example 0.5 means the
    /// host encodes at half resolution and MetalFX upscales 2× on the client.
    static func upscaleFactor() -> Double {
        let value = UserDefaults.standard.double(forKey: upscaleFactorKey)
        guard value > 0 else { return 0.5 }
        return min(0.75, max(0.5, value))
    }
}
