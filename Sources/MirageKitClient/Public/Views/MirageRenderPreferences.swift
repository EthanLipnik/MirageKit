//
//  MirageRenderPreferences.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/23/26.
//

import Foundation

enum MirageRenderPreferences {
    private static let frameRatePresetKey = "frameratePreset"

    static func preferredMaximumRefreshRate() -> Int {
        preferredMaximumRefreshRate(frameratePresetRawValue: UserDefaults.standard.string(forKey: frameRatePresetKey))
    }

    static func preferredMaximumRefreshRate(frameratePresetRawValue: String?) -> Int {
        switch frameratePresetRawValue {
        case "20fps":
            20
        case "30fps":
            30
        case "60fps":
            60
        case "90fps":
            90
        case "120fps":
            120
        default:
            60
        }
    }
}
