//
//  MirageRenderPreferences.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/23/26.
//

import Foundation
import MirageKit

enum MirageRenderPreferences {
    static func proMotionEnabled() -> Bool {
        UserDefaults.standard.object(forKey: "enableProMotion") as? Bool ?? false
    }

    static func allowAdaptiveFallback() -> Bool {
        UserDefaults.standard.object(forKey: "allowAdaptiveFallback") as? Bool ?? false
    }

    static func latencyMode() -> MirageStreamLatencyMode {
        guard let rawValue = UserDefaults.standard.string(forKey: "latencyMode"),
              let mode = MirageStreamLatencyMode(rawValue: rawValue) else {
            return .auto
        }
        return mode
    }
}
