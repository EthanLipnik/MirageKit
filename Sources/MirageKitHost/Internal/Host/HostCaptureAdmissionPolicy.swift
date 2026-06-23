//
//  HostCaptureAdmissionPolicy.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 6/1/26.
//

import Foundation
import MirageKit

#if os(macOS)
struct HostCaptureAdmissionPolicy: Sendable, Equatable {
    struct EncoderLagSnapshot: Sendable, Equatable {
        let averageEncodeMs: Double
        let inFlightCount: Int
        let frameRate: Int

        init(
            averageEncodeMs: Double,
            inFlightCount: Int,
            frameRate: Int
        ) {
            self.averageEncodeMs = max(0, averageEncodeMs)
            self.inFlightCount = max(0, inFlightCount)
            self.frameRate = max(1, frameRate)
        }
    }

    static func shouldDropCapturedFrame(
        latencyMode: MirageStreamLatencyMode,
        hostBufferingPolicy: MirageHostBufferingPolicy,
        pendingFrameCount: Int,
        frameCapacity: Int,
        backpressureActive: Bool,
        encoderLag: EncoderLagSnapshot? = nil
    ) -> Bool {
        let capacity = max(1, frameCapacity)
        let pending = max(0, pendingFrameCount)

        if backpressureActive {
            let dropThreshold = backpressureDropThreshold(
                capacity: capacity,
                encoderLag: encoderLag
            )
            return pending >= dropThreshold
        }

        if let encoderLag, isEncoderLagging(encoderLag, latencyMode: latencyMode) {
            if prefersNewestFrameReplacementUnderEncoderLag(
                latencyMode: latencyMode,
                hostBufferingPolicy: hostBufferingPolicy,
                pendingFrameCount: pending,
                frameCapacity: capacity,
                encoderLag: encoderLag
            ) {
                return false
            }
        }

        if latencyMode == .lowestLatency, hostBufferingPolicy == .freshestFrame {
            return false
        }

        return pending >= capacity
    }

    static func shouldDrainNewestBeforeEncode(
        latencyMode: MirageStreamLatencyMode,
        hostBufferingPolicy: MirageHostBufferingPolicy,
        pendingFrameCount: Int,
        frameCapacity: Int,
        encoderLag: EncoderLagSnapshot
    ) -> Bool {
        let pending = max(0, pendingFrameCount)
        let capacity = max(1, frameCapacity)
        guard pending > 1 else { return false }
        guard isEncoderLagging(encoderLag, latencyMode: latencyMode) else { return false }

        let backlogMs = estimatedPreEncodeBacklogMs(
            pendingFrameCount: pending,
            encoderLag: encoderLag
        )
        if latencyMode == .lowestLatency, hostBufferingPolicy == .freshestFrame {
            guard encoderLag.frameRate >= 90, capacity > 1 else { return true }
            let queuedBacklogMs = estimatedQueuedFrameBacklogMs(
                pendingFrameCount: pending,
                encoderLag: encoderLag
            )
            return pending >= max(2, capacity) ||
                queuedBacklogMs >= preEncodeBacklogCapMs(
                    latencyMode: latencyMode,
                    frameRate: encoderLag.frameRate
                )
        }

        if backlogMs >= preEncodeBacklogCapMs(
            latencyMode: latencyMode,
            frameRate: encoderLag.frameRate
        ) {
            return true
        }

        switch latencyMode {
        case .lowestLatency:
            return pending >= max(2, capacity)
        case .balanced:
            return pending >= max(2, capacity - 1)
        case .smoothest:
            return pending >= capacity
        }
    }

    static func isEncoderLagging(
        _ snapshot: EncoderLagSnapshot,
        latencyMode: MirageStreamLatencyMode
    ) -> Bool {
        guard snapshot.averageEncodeMs > 0 else { return false }
        let budget = frameBudgetMs(frameRate: snapshot.frameRate)
        return snapshot.averageEncodeMs >= budget * encodeBudgetMultiplier(for: latencyMode)
    }

    static func estimatedPreEncodeBacklogMs(
        pendingFrameCount: Int,
        encoderLag: EncoderLagSnapshot
    ) -> Double {
        Double(max(0, pendingFrameCount) + max(0, encoderLag.inFlightCount)) *
            max(frameBudgetMs(frameRate: encoderLag.frameRate), encoderLag.averageEncodeMs)
    }

    static func estimatedQueuedFrameBacklogMs(
        pendingFrameCount: Int,
        encoderLag: EncoderLagSnapshot
    ) -> Double {
        Double(max(0, pendingFrameCount)) *
            max(frameBudgetMs(frameRate: encoderLag.frameRate), encoderLag.averageEncodeMs)
    }

    static func preEncodeBacklogCapMs(
        latencyMode: MirageStreamLatencyMode,
        frameRate: Int
    ) -> Double {
        let budget = frameBudgetMs(frameRate: frameRate)
        switch latencyMode {
        case .lowestLatency:
            if frameRate >= 90 { return max(64, budget * 6) }
            return max(24, budget * 1.5)
        case .balanced:
            return max(140, budget * 8)
        case .smoothest:
            return min(3_000, max(650, budget * 36))
        }
    }

    private static func prefersNewestFrameReplacementUnderEncoderLag(
        latencyMode: MirageStreamLatencyMode,
        hostBufferingPolicy: MirageHostBufferingPolicy,
        pendingFrameCount: Int,
        frameCapacity: Int,
        encoderLag: EncoderLagSnapshot
    ) -> Bool {
        let pending = max(0, pendingFrameCount)
        let capacity = max(1, frameCapacity)
        guard pending >= capacity else { return false }

        if hostBufferingPolicy == .freshestFrame { return true }

        if shouldDrainNewestBeforeEncode(
            latencyMode: latencyMode,
            hostBufferingPolicy: hostBufferingPolicy,
            pendingFrameCount: pending,
            frameCapacity: capacity,
            encoderLag: encoderLag
        ) {
            return true
        }

        let backlogMs = estimatedPreEncodeBacklogMs(
            pendingFrameCount: pending,
            encoderLag: encoderLag
        )
        return backlogMs >= preEncodeBacklogCapMs(
            latencyMode: latencyMode,
            frameRate: encoderLag.frameRate
        )
    }

    private static func backpressureDropThreshold(
        capacity: Int,
        encoderLag: EncoderLagSnapshot?
    ) -> Int {
        guard let encoderLag,
              encoderLag.frameRate >= 90,
              capacity > 1 else {
            return max(1, capacity - 1)
        }
        return capacity
    }

    private static func frameBudgetMs(frameRate: Int) -> Double {
        1_000.0 / Double(admissionBudgetFrameRate(for: frameRate))
    }

    private static func admissionBudgetFrameRate(for frameRate: Int) -> Int {
        let frameRate = max(1, frameRate)
        guard frameRate > 60 else { return frameRate }
        return 60
    }

    private static func encodeBudgetMultiplier(for latencyMode: MirageStreamLatencyMode) -> Double {
        switch latencyMode {
        case .lowestLatency:
            return 1.08
        case .balanced:
            return 1.25
        case .smoothest:
            return 1.65
        }
    }
}
#endif
