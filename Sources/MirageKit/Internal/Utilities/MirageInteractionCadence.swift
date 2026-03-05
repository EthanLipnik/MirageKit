//
//  MirageInteractionCadence.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/4/26.
//

import Foundation

package enum MirageInteractionCadence {
    package static let targetFPS120: Int = 120
    package static let frameInterval120Nanoseconds: Int = 8_333_333
    package static let frameInterval120Seconds: TimeInterval = 1.0 / 120.0
    package static let frameInterval120Duration: Duration = .nanoseconds(frameInterval120Nanoseconds)
}
