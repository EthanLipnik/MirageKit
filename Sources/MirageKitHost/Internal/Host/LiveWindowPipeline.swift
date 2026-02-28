//
//  LiveWindowPipeline.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/27/26.
//

import Foundation
import MirageKit

#if os(macOS)
actor LiveWindowPipeline {
    private struct AppliedState: Sendable {
        var frameRate: Int?
        var bitrateBps: Int?
        var lastFrameRateApplyAt: CFAbsoluteTime = 0
        var lastBitrateApplyAt: CFAbsoluteTime = 0
        var appliedFrameRateUpdates: Int = 0
        var appliedBitrateUpdates: Int = 0
    }

    struct DebugState: Sendable {
        let frameRate: Int?
        let bitrateBps: Int?
        let appliedFrameRateUpdates: Int
        let appliedBitrateUpdates: Int
    }

    private var appliedStateByStreamID: [StreamID: AppliedState] = [:]
    private let minimumApplyInterval: CFAbsoluteTime = 0.250

    func apply(
        streamID: StreamID,
        context: StreamContext,
        targetFrameRate: Int,
        targetBitrateBps: Int?,
        requestRecoveryKeyframe: Bool
    ) async {
        let now = CFAbsoluteTimeGetCurrent()
        var state = appliedStateByStreamID[streamID] ?? AppliedState()

        let clampedFrameRate = max(1, targetFrameRate)
        let shouldApplyFrameRate = shouldApplyFrameRate(
            state: state,
            targetFrameRate: clampedFrameRate,
            now: now
        )

        if shouldApplyFrameRate {
            do {
                try await context.updateFrameRate(clampedFrameRate)
                state.frameRate = clampedFrameRate
                state.lastFrameRateApplyAt = now
                state.appliedFrameRateUpdates += 1
            } catch {
                MirageLogger.error(.host, error: error, message: "Failed to apply live frame rate: ")
            }
        }

        if let targetBitrateBps,
           shouldApplyBitrate(
               state: state,
               targetBitrateBps: targetBitrateBps,
               now: now
           ) {
            do {
                try await context.updateEncoderSettings(
                    bitDepth: nil,
                    bitrate: targetBitrateBps
                )
                state.bitrateBps = targetBitrateBps
                state.lastBitrateApplyAt = now
                state.appliedBitrateUpdates += 1
            } catch {
                MirageLogger.error(.host, error: error, message: "Failed to apply live bitrate: ")
            }
        }

        appliedStateByStreamID[streamID] = state

        if requestRecoveryKeyframe {
            await context.requestKeyframe()
        }
    }

    func clear(streamID: StreamID) {
        appliedStateByStreamID.removeValue(forKey: streamID)
    }

    func debugState(streamID: StreamID) -> DebugState? {
        guard let state = appliedStateByStreamID[streamID] else { return nil }
        return DebugState(
            frameRate: state.frameRate,
            bitrateBps: state.bitrateBps,
            appliedFrameRateUpdates: state.appliedFrameRateUpdates,
            appliedBitrateUpdates: state.appliedBitrateUpdates
        )
    }

    private func shouldApplyFrameRate(
        state: AppliedState,
        targetFrameRate: Int,
        now: CFAbsoluteTime
    ) -> Bool {
        if state.frameRate == nil { return true }
        guard state.frameRate != targetFrameRate else { return false }
        return now - state.lastFrameRateApplyAt >= minimumApplyInterval
    }

    private func shouldApplyBitrate(
        state: AppliedState,
        targetBitrateBps: Int,
        now: CFAbsoluteTime
    ) -> Bool {
        guard let current = state.bitrateBps else { return true }
        let delta = abs(current - targetBitrateBps)
        let minimumDelta = max(1_000_000, Int(Double(max(current, 1)) * 0.10))
        guard delta >= minimumDelta else { return false }
        return now - state.lastBitrateApplyAt >= minimumApplyInterval
    }
}
#endif
