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
}
