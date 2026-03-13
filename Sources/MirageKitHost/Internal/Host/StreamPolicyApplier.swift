//
//  StreamPolicyApplier.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/28/26.
//

import Foundation
import MirageKit

#if os(macOS)
actor StreamPolicyApplier {
    struct DiagnosticSnapshot: Sendable {
        let appliedUpdates: Int
        let suppressedNoOpUpdates: Int
        let suppressedCooldownUpdates: Int
    }

    private struct AppliedStreamState: Sendable {
        var lastPolicy: MirageStreamPolicy?
        var lastAppliedAt: CFAbsoluteTime = 0
        var appliedUpdates: Int = 0
        var suppressedNoOpUpdates: Int = 0
        var suppressedCooldownUpdates: Int = 0
    }

    private let minimumApplyInterval: CFAbsoluteTime = 0.500
    private var statesByStreamID: [StreamID: AppliedStreamState] = [:]

    func apply(
        policy: MirageStreamPolicy,
        context: StreamContext,
        requestRecoveryKeyframe: Bool
    ) async {
        var state = statesByStreamID[policy.streamID] ?? AppliedStreamState()
        let now = CFAbsoluteTimeGetCurrent()

        if state.lastPolicy == policy {
            state.suppressedNoOpUpdates += 1
            statesByStreamID[policy.streamID] = state
            return
        }
        if state.lastAppliedAt > 0,
           now - state.lastAppliedAt < minimumApplyInterval {
            state.suppressedCooldownUpdates += 1
            statesByStreamID[policy.streamID] = state
            return
        }

        do {
            try await context.updateFrameRate(policy.targetFPS)
            try await context.updateEncoderSettings(
                colorDepth: nil,
                bitrate: policy.targetBitrateBps
            )
            if requestRecoveryKeyframe, policy.tier == .activeLive {
                await context.requestKeyframe()
            }
            state.lastPolicy = policy
            state.lastAppliedAt = now
            state.appliedUpdates += 1
            statesByStreamID[policy.streamID] = state
        } catch {
            MirageLogger.error(.host, error: error, message: "Failed to apply stream policy: ")
        }
    }

    func clear(streamID: StreamID) {
        statesByStreamID.removeValue(forKey: streamID)
    }

    func diagnostics(streamID: StreamID) -> DiagnosticSnapshot? {
        guard let state = statesByStreamID[streamID] else { return nil }
        return DiagnosticSnapshot(
            appliedUpdates: state.appliedUpdates,
            suppressedNoOpUpdates: state.suppressedNoOpUpdates,
            suppressedCooldownUpdates: state.suppressedCooldownUpdates
        )
    }
}
#endif
