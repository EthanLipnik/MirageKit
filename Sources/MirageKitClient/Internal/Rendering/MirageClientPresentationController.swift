//
//  MirageClientPresentationController.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/14/26.
//

import Foundation

/// Selects decoded frames for client-owned presentation.
struct MirageClientPresentationController {
    private var playoutBuffer = MirageVideoPlayoutBuffer()

    mutating func reset() {
        playoutBuffer.reset()
    }

    mutating func enqueue(
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

    mutating func nextFrame(
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

    mutating func trimAfterPolicyChange(
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

    mutating func recordDisplayTickWithoutFrame(
        policy: MiragePresentationLatencyPolicy,
        now: CFAbsoluteTime
    ) {
        playoutBuffer.recordDisplayTickWithoutFrame(
            policy: policy,
            now: now
        )
    }

    mutating func recordFrameArrivedAfterEmptyTick(
        policy: MiragePresentationLatencyPolicy,
        now: CFAbsoluteTime
    ) {
        playoutBuffer.recordFrameArrivedAfterEmptyTick(
            policy: policy,
            now: now
        )
    }

    func smoothestDisplayDebtMs(
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

    func smoothestTargetDelayMs(policy: MiragePresentationLatencyPolicy) -> Double {
        playoutBuffer.smoothestTargetDelayMs(policy: policy)
    }
}
