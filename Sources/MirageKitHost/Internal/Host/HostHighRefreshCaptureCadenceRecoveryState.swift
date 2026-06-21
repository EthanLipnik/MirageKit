//
//  HostHighRefreshCaptureCadenceRecoveryState.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 6/20/26.
//

import CoreFoundation
import Foundation

#if os(macOS)
struct HostHighRefreshCaptureCadenceRecoveryState: Sendable, Equatable {
    enum Stage: String, Sendable, Equatable {
        case observing
        case nativeRefreshRetuned = "native-refresh-retuned"
        case explicitTargetRetuned = "explicit-target-retuned"
        case captureRestarted = "capture-restarted"
        case exhausted
    }

    static let minimumHighRefreshTargetFPS = 90
    static let deficitSampleThreshold = 2
    static let healthySampleThreshold = 3
    static let actionCooldownSeconds: CFAbsoluteTime = 2.0

    var stage: Stage = .observing
    var deficitSampleCount = 0
    var healthySampleCount = 0
    var firstDeficitTime: CFAbsoluteTime = 0
    var lastActionTime: CFAbsoluteTime = 0

    mutating func noteDeficit(now: CFAbsoluteTime) -> Bool {
        if firstDeficitTime <= 0 || now - firstDeficitTime > 8.0 {
            firstDeficitTime = now
            deficitSampleCount = 0
        }
        healthySampleCount = 0
        deficitSampleCount += 1
        return deficitSampleCount >= Self.deficitSampleThreshold
    }

    mutating func noteHealthy(now: CFAbsoluteTime) {
        deficitSampleCount = 0
        firstDeficitTime = 0
        healthySampleCount += 1
        if healthySampleCount >= Self.healthySampleThreshold {
            reset(keepingLastActionTime: true)
            lastActionTime = now
        }
    }

    func canAct(now: CFAbsoluteTime) -> Bool {
        lastActionTime <= 0 || now - lastActionTime >= Self.actionCooldownSeconds
    }

    mutating func recordAction(_ nextStage: Stage, now: CFAbsoluteTime) {
        stage = nextStage
        lastActionTime = now
        deficitSampleCount = 0
        healthySampleCount = 0
        firstDeficitTime = 0
    }

    mutating func reset(keepingLastActionTime: Bool = false) {
        let retainedLastActionTime = lastActionTime
        stage = .observing
        deficitSampleCount = 0
        healthySampleCount = 0
        firstDeficitTime = 0
        lastActionTime = keepingLastActionTime ? retainedLastActionTime : 0
    }
}
#endif
