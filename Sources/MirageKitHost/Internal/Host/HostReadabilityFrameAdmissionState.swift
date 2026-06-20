//
//  HostReadabilityFrameAdmissionState.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 6/19/26.
//

import CoreFoundation
import Foundation

#if os(macOS)
struct HostReadabilityFrameAdmissionState: Sendable, Equatable {
    enum Mode: String, Sendable, Equatable {
        case inactive
        case protecting
    }

    static let admitTargetFPS = 20
    static let minimumFrameIntervalMs = 50.0

    var mode: Mode = .inactive
    var reason: String?
    var firstSkipTime: CFAbsoluteTime = 0
    var lastSkipTime: CFAbsoluteTime = 0
    var lastAdmittedFrameTime: CFAbsoluteTime = 0
    var lastSkipLogTime: CFAbsoluteTime = 0
    var totalSkipCount: UInt64 = 0
    var skipBurstCount: UInt64 = 0

    var isActive: Bool {
        mode == .protecting
    }

    var minimumFrameIntervalSeconds: CFAbsoluteTime {
        Self.minimumFrameIntervalMs / 1_000.0
    }

    mutating func reset(admittedAt now: CFAbsoluteTime? = nil) {
        mode = .inactive
        reason = nil
        firstSkipTime = 0
        lastSkipTime = 0
        if let now {
            lastAdmittedFrameTime = now
        }
        skipBurstCount = 0
    }

    mutating func evaluateAdmission(
        currentFrameRate: Int,
        reason: String,
        now: CFAbsoluteTime
    ) -> Bool {
        guard currentFrameRate > Self.admitTargetFPS else {
            reset(admittedAt: now)
            return false
        }

        guard lastAdmittedFrameTime > 0 else {
            lastAdmittedFrameTime = now
            return false
        }

        if now - lastAdmittedFrameTime >= minimumFrameIntervalSeconds {
            lastAdmittedFrameTime = now
            return false
        }

        mode = .protecting
        self.reason = reason
        if lastSkipTime <= 0 || now - lastSkipTime > 1.0 {
            firstSkipTime = now
            skipBurstCount = 0
        }
        lastSkipTime = now
        totalSkipCount &+= 1
        skipBurstCount &+= 1
        return true
    }
}
#endif
