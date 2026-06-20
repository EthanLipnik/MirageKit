//
//  HostReadabilityFloorRecoveryState.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 6/20/26.
//

import CoreFoundation
import Foundation

#if os(macOS)
struct HostReadabilityFloorRecoveryState: Sendable, Equatable {
    enum Mode: String, Sendable, Equatable {
        case inactive
        case floorWarming = "floor-warming"
        case floorProtecting = "floor-protecting"
    }

    static let emergencyGraceSeconds: CFAbsoluteTime = 0.75

    var mode: Mode = .inactive
    var reason: String?
    var firstEligibleTime: CFAbsoluteTime = 0
    var lastEligibleTime: CFAbsoluteTime = 0
    var lastTransitionLogTime: CFAbsoluteTime = 0

    var isProtecting: Bool {
        mode == .floorProtecting
    }

    mutating func reset() {
        mode = .inactive
        reason = nil
        firstEligibleTime = 0
        lastEligibleTime = 0
    }

    @discardableResult
    mutating func update(reason: String, now: CFAbsoluteTime) -> Bool {
        if self.reason != reason ||
            firstEligibleTime <= 0 ||
            now - lastEligibleTime > Self.emergencyGraceSeconds {
            firstEligibleTime = now
            mode = .floorWarming
        }

        self.reason = reason
        lastEligibleTime = now

        if now - firstEligibleTime >= Self.emergencyGraceSeconds {
            mode = .floorProtecting
            return true
        }
        return false
    }
}
#endif
