//
//  MirageRenderAdmission.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/12/26.
//
//  Render admission policy and lock-protected in-flight accounting.
//

import Foundation
import MirageKit

enum MirageRenderPolicyReason: String, Equatable {
    case baseline
    case typing
    case recovery
    case promotion
}

struct MirageRenderPolicyDecision: Equatable {
    let inFlightCap: Int
    let maximumDrawableCount: Int
    let reason: MirageRenderPolicyReason
    let allowsSecondaryCatchUpDraw: Bool
}

enum MirageRenderAdmissionPolicy {
    static func effectiveInFlightCap(targetFPS: Int, maximumDrawableCount: Int) -> Int {
        let desiredInFlight = targetFPS >= 120 ? 3 : 3
        return max(1, min(desiredInFlight, maximumDrawableCount))
    }

    static func decision(
        latencyMode: MirageStreamLatencyMode,
        targetFPS: Int,
        typingBurstActive: Bool,
        recoveryActive: Bool,
        smoothestPromotionActive: Bool
    ) -> MirageRenderPolicyDecision {
        let normalizedTargetFPS = targetFPS >= 120 ? 120 : 60
        let maximumDrawableCount = resolvedMaximumDrawableCount(
            latencyMode: latencyMode,
            targetFPS: normalizedTargetFPS,
            smoothestPromotionActive: smoothestPromotionActive
        )
        let inFlightChoice = resolvedInFlightCap(
            latencyMode: latencyMode,
            targetFPS: normalizedTargetFPS,
            typingBurstActive: typingBurstActive,
            recoveryActive: recoveryActive,
            smoothestPromotionActive: smoothestPromotionActive
        )
        let inFlightCap = max(1, min(inFlightChoice.cap, maximumDrawableCount))
        return MirageRenderPolicyDecision(
            inFlightCap: inFlightCap,
            maximumDrawableCount: maximumDrawableCount,
            reason: inFlightChoice.reason,
            allowsSecondaryCatchUpDraw: allowsSecondaryCatchUpDraw(
                latencyMode: latencyMode,
                targetFPS: normalizedTargetFPS,
                smoothestPromotionActive: smoothestPromotionActive,
                reason: inFlightChoice.reason
            )
        )
    }

    private static func resolvedInFlightCap(
        latencyMode: MirageStreamLatencyMode,
        targetFPS: Int,
        typingBurstActive: Bool,
        recoveryActive: Bool,
        smoothestPromotionActive: Bool
    ) -> (cap: Int, reason: MirageRenderPolicyReason) {
        if recoveryActive {
            return (1, .recovery)
        }
        if targetFPS >= 120 {
            return (3, .baseline)
        }

        switch latencyMode {
        case .lowestLatency:
            return (1, .baseline)
        case .auto:
            if typingBurstActive {
                return (1, .typing)
            }
            return (2, .baseline)
        case .smoothest:
            if smoothestPromotionActive {
                return (3, .promotion)
            }
            return (2, .baseline)
        }
    }

    private static func resolvedMaximumDrawableCount(
        latencyMode: MirageStreamLatencyMode,
        targetFPS: Int,
        smoothestPromotionActive: Bool
    ) -> Int {
        if targetFPS >= 120 {
            return 3
        }
        switch latencyMode {
        case .lowestLatency, .auto:
            return 2
        case .smoothest:
            return smoothestPromotionActive ? 3 : 2
        }
    }

    private static func allowsSecondaryCatchUpDraw(
        latencyMode: MirageStreamLatencyMode,
        targetFPS: Int,
        smoothestPromotionActive: Bool,
        reason: MirageRenderPolicyReason
    ) -> Bool {
        if targetFPS >= 120 {
            return true
        }
        switch latencyMode {
        case .smoothest:
            return smoothestPromotionActive && reason == .promotion
        case .lowestLatency, .auto:
            return false
        }
    }
}

final class MirageRenderAdmissionCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var inFlightRenders: Int = 0

    @discardableResult
    func tryAcquire(limit: Int) -> Bool {
        let clampedLimit = max(1, limit)
        lock.lock()
        defer { lock.unlock() }
        guard inFlightRenders < clampedLimit else { return false }
        inFlightRenders &+= 1
        return true
    }

    @discardableResult
    func release() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard inFlightRenders > 0 else { return false }
        inFlightRenders -= 1
        return true
    }

    func reset() {
        lock.lock()
        inFlightRenders = 0
        lock.unlock()
    }

    func snapshot() -> Int {
        lock.lock()
        let value = inFlightRenders
        lock.unlock()
        return value
    }
}

/// Prevents stale frame presentation when concurrent drawable waits complete out-of-order.
final class MirageRenderSequenceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var latestRequestedSequence: UInt64 = 0
    private var latestPresentedSequence: UInt64 = 0

    func reset() {
        lock.lock()
        latestRequestedSequence = 0
        latestPresentedSequence = 0
        lock.unlock()
    }

    func noteRequested(_ sequence: UInt64) {
        lock.lock()
        // Frame-cache resets restart sequence numbering at 1.
        // Any backward jump indicates a new sequence space.
        if sequence < latestRequestedSequence || sequence < latestPresentedSequence {
            latestRequestedSequence = 0
            latestPresentedSequence = 0
        }
        if sequence > latestRequestedSequence {
            latestRequestedSequence = sequence
        }
        lock.unlock()
    }

    func notePresented(_ sequence: UInt64) {
        lock.lock()
        if sequence > latestPresentedSequence {
            latestPresentedSequence = sequence
        }
        lock.unlock()
    }

    func isStale(_ sequence: UInt64) -> Bool {
        lock.lock()
        let stale = sequence <= latestPresentedSequence
        lock.unlock()
        return stale
    }
}
