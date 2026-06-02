//
//  StreamControllerRecoveryPolicy.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/9/26.
//
//  Pure stream recovery timing helpers.
//

import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

extension StreamController {
    nonisolated static func frameIntervalSeconds(targetFPS: Int) -> CFAbsoluteTime {
        1.0 / Double(max(1, targetFPS))
    }

    nonisolated static func keyframeRequestCoalesceInterval(targetFPS: Int) -> CFAbsoluteTime {
        let frameScaledInterval = frameIntervalSeconds(targetFPS: targetFPS) * 24.0
        return max(recoveryRequestDispatchCooldown, min(1.0, frameScaledInterval))
    }

    nonisolated static func keyframeProgressFreshThreshold(targetFPS: Int) -> CFAbsoluteTime {
        let frameScaledThreshold = frameIntervalSeconds(targetFPS: targetFPS) * 18.0
        return min(0.50, max(0.15, frameScaledThreshold))
    }

    nonisolated static func shouldDeferForPendingKeyframeProgress(
        _ progress: FrameReassembler.PendingKeyframeProgress,
        now: CFAbsoluteTime,
        targetFPS: Int
    ) -> Bool {
        let recentProgress = now - progress.lastProgressTime <
            keyframeProgressFreshThreshold(targetFPS: targetFPS)
        if recentProgress { return true }

        let frameScaledBase = frameIntervalSeconds(targetFPS: targetFPS) * 90.0
        let baseAssemblyWindow = min(3.0, max(0.75, frameScaledBase))
        let progressBonus: CFAbsoluteTime
        if progress.progressRatio >= 0.75 {
            progressBonus = 2.0
        } else if progress.progressRatio >= 0.25 {
            progressBonus = 1.0
        } else {
            progressBonus = 0
        }
        return progress.age < baseAssemblyWindow + progressBonus
    }

    nonisolated static func keyframeRecoveryRetryDelay(
        attempt: Int,
        targetFPS: Int
    )
    -> CFAbsoluteTime {
        RecoveryCoordinator.defaultRetryDelay(targetFPS: targetFPS, attempt: attempt + 1)
    }

    nonisolated static func duration(seconds: CFAbsoluteTime) -> Duration {
        .milliseconds(Int64(max(1, Int((seconds * 1000).rounded(.up)))))
    }

    nonisolated static func frameLossDiagnosticMessage(
        streamID: StreamID,
        reason: FrameReassembler.FrameLossReason
    ) -> String? {
        guard reason == .severeForwardGap else { return nil }
        return "Severe forward gap recovery fired for stream \(streamID); treating this as a short gap-recovery dip rather than a sustained host cadence collapse"
    }

    nonisolated static func defaultApplicationForegroundProvider() async -> Bool {
        #if canImport(UIKit)
        return await MainActor.run {
            UIApplication.shared.applicationState == .active
        }
        #elseif canImport(AppKit)
        return await MainActor.run {
            NSApp?.isActive ?? true
        }
        #else
        return true
        #endif
    }
}
