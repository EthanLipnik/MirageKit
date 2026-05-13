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
    /// Minimum interval between applying changed policies to the same stream.
    private static let minimumApplyInterval: CFAbsoluteTime = 0.500

    private struct AppliedStreamState: Sendable {
        var lastPolicy: MirageStreamPolicy?
        var lastAppliedAt: CFAbsoluteTime = 0
    }

    private var statesByStreamID: [StreamID: AppliedStreamState] = [:]

    func apply(
        policy: MirageStreamPolicy,
        context: StreamContext,
        requestRecoveryKeyframe: Bool
    ) async {
        var state = statesByStreamID[policy.streamID] ?? AppliedStreamState()
        let now = CFAbsoluteTimeGetCurrent()

        if state.lastPolicy == policy {
            return
        }
        if state.lastAppliedAt > 0,
           now - state.lastAppliedAt < Self.minimumApplyInterval {
            return
        }

        do {
            try await context.updateFrameRate(policy.targetFPS)
            try await context.updateEncoderSettings(
                colorDepth: nil,
                bitrate: policy.targetBitrateBps
            )
            if requestRecoveryKeyframe, policy.tier == .activeLive {
                await context.requestKeyframeRecoveryIfPossible()
            }
            state.lastPolicy = policy
            state.lastAppliedAt = now
            statesByStreamID[policy.streamID] = state
        } catch {
            MirageLogger.error(.host, error: error, message: "Failed to apply stream policy: ")
        }
    }

    func clear(streamID: StreamID) {
        statesByStreamID.removeValue(forKey: streamID)
    }
}
#endif
