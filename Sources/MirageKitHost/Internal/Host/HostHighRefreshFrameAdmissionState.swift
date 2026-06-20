//
//  HostHighRefreshFrameAdmissionState.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 6/19/26.
//

import CoreFoundation
import Foundation

#if os(macOS)
struct HostHighRefreshFrameAdmissionState: Sendable, Equatable {
    enum Mode: String, Sendable, Equatable {
        case inactive
        case protecting
    }

    static let protectedFloorFPS = 60

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

    mutating func reset(admittedAt now: CFAbsoluteTime? = nil) {
        mode = .inactive
        reason = nil
        firstSkipTime = 0
        lastSkipTime = 0
        lastAdmittedFrameTime = now ?? 0
        skipBurstCount = 0
    }

    mutating func evaluateAdmission(
        currentFrameRate: Int,
        frameCaptureTime: CFAbsoluteTime,
        reason: String?,
        now: CFAbsoluteTime
    ) -> Bool {
        guard currentFrameRate > Self.protectedFloorFPS,
              let reason else {
            reset(admittedAt: now)
            return false
        }

        let protectedFloorInterval = 1.0 / Double(Self.protectedFloorFPS)
        let frameAge = max(0, now - frameCaptureTime)
        guard frameAge >= protectedFloorInterval else {
            reset(admittedAt: now)
            return false
        }

        guard lastAdmittedFrameTime > 0 else {
            lastAdmittedFrameTime = now
            return false
        }

        let elapsedSinceAdmission = now - lastAdmittedFrameTime
        guard elapsedSinceAdmission < protectedFloorInterval else {
            reset(admittedAt: now)
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
