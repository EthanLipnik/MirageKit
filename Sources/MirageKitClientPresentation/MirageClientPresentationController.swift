//
//  MirageClientPresentationController.swift
//  MirageKitClientPresentation
//
//  Created by Ethan Lipnik on 5/14/26.
//

import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageKit
import MirageMedia
import MirageWire
import Foundation

/// Selects decoded frames for client-owned presentation.
package struct MirageClientPresentationController {
    private var playoutBuffer = MirageVideoPlayoutBuffer()

    package init() {}

    package mutating func reset() {
        playoutBuffer.reset()
    }

    package mutating func resetPresentationEpoch(
        policy: MiragePresentationLatencyPolicy,
        now: CFAbsoluteTime
    ) {
        playoutBuffer.resetPresentationEpoch(
            policy: policy,
            now: now
        )
    }

    package mutating func enqueue(
        _ frame: MirageRenderFrame,
        into frames: inout [MirageRenderFrame],
        policy: MiragePresentationLatencyPolicy,
        now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    ) -> MirageVideoPlayoutBuffer.TrimResult {
        playoutBuffer.enqueue(
            frame,
            into: &frames,
            policy: policy,
            now: now
        )
    }

    package mutating func nextFrame(
        frames: inout [MirageRenderFrame],
        after submittedCursor: MirageRenderCursor,
        policy: MiragePresentationLatencyPolicy,
        now: CFAbsoluteTime
    ) -> MirageVideoPlayoutBuffer.Selection {
        playoutBuffer.selectFrame(
            frames: &frames,
            after: submittedCursor,
            policy: policy,
            now: now
        )
    }

    package mutating func trimAfterPolicyChange(
        frames: inout [MirageRenderFrame],
        policy: MiragePresentationLatencyPolicy,
        now: CFAbsoluteTime
    ) -> MirageVideoPlayoutBuffer.TrimResult {
        playoutBuffer.trimAfterPolicyChange(
            frames: &frames,
            policy: policy,
            now: now
        )
    }

    package mutating func recordDisplayTickWithoutFrame(
        policy: MiragePresentationLatencyPolicy,
        now: CFAbsoluteTime
    ) {
        playoutBuffer.recordDisplayTickWithoutFrame(
            policy: policy,
            now: now
        )
    }

    package mutating func recordFrameArrivedAfterEmptyTick(
        policy: MiragePresentationLatencyPolicy,
        now: CFAbsoluteTime
    ) {
        playoutBuffer.recordFrameArrivedAfterEmptyTick(
            policy: policy,
            now: now
        )
    }

    package func smoothestDisplayDebtMs(
        frames: [MirageRenderFrame],
        policy: MiragePresentationLatencyPolicy,
        now: CFAbsoluteTime
    ) -> Double {
        playoutBuffer.smoothestDisplayDebtMs(
            frames: frames,
            policy: policy,
            now: now
        )
    }

    package func smoothestTargetDelayMs(policy: MiragePresentationLatencyPolicy) -> Double {
        playoutBuffer.smoothestTargetDelayMs(policy: policy)
    }
}
