//
//  HostFrameFreshnessPolicy.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/31/26.
//

import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageKit
import MirageKitClientPresentation
import MirageMedia
import MirageWire
import CoreFoundation
import Foundation

#if os(macOS)
struct HostFrameFreshnessPolicy: Sendable, Equatable {
    let latencyMode: MirageMedia.MirageStreamLatencyMode
    let frameRate: Int
    let inputActiveWindow: CFTimeInterval
    let stillContentWindow: CFTimeInterval
    let inputMaxPresentationDepth: Int
    let passiveMotionMaxPresentationDepth: Int
    let stillMaxPresentationDepth: Int
    let inputPresentationAgeCapMs: Double
    let passiveMotionPresentationAgeCapMs: Double
    let inputMaxUnstartedPFrames: Int
    let passiveMotionMaxUnstartedPFrames: Int
    let stillMaxUnstartedPFrames: Int
    let inputQueuedPFrameAgeCapMs: Double
    let passiveMotionQueuedPFrameAgeCapMs: Double
    let stillQueuedPFrameAgeCapMs: Double
    let stillQualityProbeInterval: CFTimeInterval
    let stillQualityKeyframeInterval: CFTimeInterval

    static func policy(
        for latencyMode: MirageMedia.MirageStreamLatencyMode,
        frameRate: Int,
        mediaPathProfile: MirageMedia.MirageMediaPathProfile = .unknown,
        receiverPlayoutDelayTargetMs: Double? = nil
    ) -> HostFrameFreshnessPolicy {
        let safeFrameRate = max(1, frameRate)
        let frameMs = 1_000.0 / Double(safeFrameRate)

        if mediaPathProfile.usesAwdlRadioPolicy {
            let playoutMs = min(
                MirageAwdlMediaController.maximumPlayoutDelayMs,
                max(
                    MirageAwdlMediaController.minimumPlayoutDelayMs,
                    receiverPlayoutDelayTargetMs ?? MirageAwdlMediaController.basePlayoutDelayMs
                )
            )
            return HostFrameFreshnessPolicy(
                latencyMode: latencyMode,
                frameRate: safeFrameRate,
                inputActiveWindow: 0.50,
                stillContentWindow: max(0.22, Double(4) / Double(safeFrameRate)),
                inputMaxPresentationDepth: 2,
                passiveMotionMaxPresentationDepth: 4,
                stillMaxPresentationDepth: 6,
                inputPresentationAgeCapMs: max(170.0, playoutMs + frameMs * 2.0),
                passiveMotionPresentationAgeCapMs: max(280.0, playoutMs + frameMs * 6.0),
                inputMaxUnstartedPFrames: 2,
                passiveMotionMaxUnstartedPFrames: 3,
                stillMaxUnstartedPFrames: 4,
                inputQueuedPFrameAgeCapMs: max(120.0, playoutMs + frameMs),
                passiveMotionQueuedPFrameAgeCapMs: max(220.0, playoutMs + frameMs * 3.0),
                stillQueuedPFrameAgeCapMs: max(420.0, playoutMs + frameMs * 12.0),
                stillQualityProbeInterval: Double(2) / Double(safeFrameRate),
                stillQualityKeyframeInterval: 2.00
            )
        }

        switch latencyMode {
        case .lowestLatency:
            return HostFrameFreshnessPolicy(
                latencyMode: latencyMode,
                frameRate: safeFrameRate,
                inputActiveWindow: 0.35,
                stillContentWindow: max(0.18, Double(3) / Double(safeFrameRate)),
                inputMaxPresentationDepth: 1,
                passiveMotionMaxPresentationDepth: 2,
                stillMaxPresentationDepth: 3,
                inputPresentationAgeCapMs: max(80.0, frameMs * 5.0),
                passiveMotionPresentationAgeCapMs: max(150.0, frameMs * 9.0),
                inputMaxUnstartedPFrames: 1,
                passiveMotionMaxUnstartedPFrames: 2,
                stillMaxUnstartedPFrames: 3,
                inputQueuedPFrameAgeCapMs: max(40.0, frameMs * 2.0),
                passiveMotionQueuedPFrameAgeCapMs: max(80.0, frameMs * 4.0),
                stillQueuedPFrameAgeCapMs: max(220.0, frameMs * 12.0),
                stillQualityProbeInterval: Double(1) / Double(safeFrameRate),
                stillQualityKeyframeInterval: 2.00
            )
        case .balanced:
            return HostFrameFreshnessPolicy(
                latencyMode: latencyMode,
                frameRate: safeFrameRate,
                inputActiveWindow: 0.50,
                stillContentWindow: max(0.22, Double(4) / Double(safeFrameRate)),
                inputMaxPresentationDepth: 2,
                passiveMotionMaxPresentationDepth: 4,
                stillMaxPresentationDepth: 4,
                inputPresentationAgeCapMs: max(125.0, frameMs * 7.0),
                passiveMotionPresentationAgeCapMs: max(250.0, frameMs * 15.0),
                inputMaxUnstartedPFrames: 2,
                passiveMotionMaxUnstartedPFrames: 4,
                stillMaxUnstartedPFrames: 4,
                inputQueuedPFrameAgeCapMs: max(80.0, frameMs * 4.0),
                passiveMotionQueuedPFrameAgeCapMs: max(140.0, frameMs * 8.0),
                stillQueuedPFrameAgeCapMs: max(320.0, frameMs * 18.0),
                stillQualityProbeInterval: Double(2) / Double(safeFrameRate),
                stillQualityKeyframeInterval: 2.00
            )
        case .smoothest:
            return HostFrameFreshnessPolicy(
                latencyMode: latencyMode,
                frameRate: safeFrameRate,
                inputActiveWindow: 0.70,
                stillContentWindow: max(0.28, Double(5) / Double(safeFrameRate)),
                inputMaxPresentationDepth: 2,
                passiveMotionMaxPresentationDepth: 6,
                stillMaxPresentationDepth: 6,
                inputPresentationAgeCapMs: max(180.0, frameMs * 10.0),
                passiveMotionPresentationAgeCapMs: max(500.0, frameMs * 30.0),
                inputMaxUnstartedPFrames: 2,
                passiveMotionMaxUnstartedPFrames: 6,
                stillMaxUnstartedPFrames: 6,
                inputQueuedPFrameAgeCapMs: max(120.0, frameMs * 7.0),
                passiveMotionQueuedPFrameAgeCapMs: max(250.0, frameMs * 15.0),
                stillQueuedPFrameAgeCapMs: max(650.0, frameMs * 36.0),
                stillQualityProbeInterval: Double(3) / Double(safeFrameRate),
                stillQualityKeyframeInterval: 2.50
            )
        }
    }

    func inputIsActive(lastInputTime: CFAbsoluteTime, now: CFAbsoluteTime) -> Bool {
        guard lastInputTime > 0 else { return false }
        return now - lastInputTime <= inputActiveWindow
    }

    func sourceIsStill(
        lastNonIdleCaptureTime: CFAbsoluteTime,
        latestFrameIsIdle: Bool,
        now: CFAbsoluteTime
    ) -> Bool {
        if latestFrameIsIdle { return true }
        guard lastNonIdleCaptureTime > 0 else { return false }
        return now - lastNonIdleCaptureTime >= stillContentWindow
    }

    func allowedPresentationDepth(inputActive: Bool, sourceStill: Bool) -> Int {
        if sourceStill, !inputActive { return stillMaxPresentationDepth }
        if inputActive { return inputMaxPresentationDepth }
        return passiveMotionMaxPresentationDepth
    }

    func presentationAgeCapMs(inputActive: Bool, sourceStill: Bool) -> Double? {
        if sourceStill, !inputActive { return nil }
        return inputActive ? inputPresentationAgeCapMs : passiveMotionPresentationAgeCapMs
    }

    func allowsPresentationFreshness(
        depth: Int,
        latestPresentedFrameAgeMs: Double?,
        inputActive: Bool,
        sourceStill: Bool
    ) -> Bool {
        guard depth <= allowedPresentationDepth(inputActive: inputActive, sourceStill: sourceStill) else {
            return false
        }
        guard let ageCap = presentationAgeCapMs(inputActive: inputActive, sourceStill: sourceStill),
              let latestPresentedFrameAgeMs else {
            return true
        }
        return latestPresentedFrameAgeMs <= ageCap
    }

    func shouldHoldPFrameReservation(
        unstartedPFrameCount: Int,
        oldestUnstartedPFrameAgeMs: Double,
        oldestUnstartedPFrameLatenessMs: Double,
        lateReservedPFrameStreak: Int,
        inputActive: Bool,
        sourceStill: Bool
    ) -> Bool {
        guard unstartedPFrameCount > 0 else { return false }

        let maxUnstartedPFrames: Int
        let ageCapMs: Double
        if sourceStill, !inputActive {
            maxUnstartedPFrames = stillMaxUnstartedPFrames
            ageCapMs = stillQueuedPFrameAgeCapMs
        } else if inputActive {
            maxUnstartedPFrames = inputMaxUnstartedPFrames
            ageCapMs = inputQueuedPFrameAgeCapMs
        } else {
            maxUnstartedPFrames = passiveMotionMaxUnstartedPFrames
            ageCapMs = passiveMotionQueuedPFrameAgeCapMs
        }

        if unstartedPFrameCount > maxUnstartedPFrames { return true }
        if oldestUnstartedPFrameAgeMs > ageCapMs { return true }

        if sourceStill, !inputActive {
            return lateReservedPFrameStreak >= 2 && oldestUnstartedPFrameLatenessMs > ageCapMs * 0.5
        }
        return oldestUnstartedPFrameLatenessMs > 0 || lateReservedPFrameStreak > 0
    }
}
#endif
