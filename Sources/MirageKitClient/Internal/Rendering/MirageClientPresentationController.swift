//
//  MirageClientPresentationController.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/14/26.
//

import Foundation

/// Selects decoded frames for client-owned presentation.
struct MirageClientPresentationController {
    func trimAfterEnqueue(
        frames: inout [MirageRenderFrame],
        policy: MiragePresentationLatencyPolicy
    ) -> MirageFramePlayoutQueue.TrimResult {
        MirageFramePlayoutQueue.trimAfterEnqueue(
            frames: &frames,
            policy: policy
        )
    }

    func nextFrame(
        frames: inout [MirageRenderFrame],
        after submittedCursor: MirageRenderCursor,
        policy: MiragePresentationLatencyPolicy,
        now: CFAbsoluteTime
    ) -> MirageFramePlayoutQueue.Selection {
        MirageFramePlayoutQueue.selectFrame(
            frames: &frames,
            after: submittedCursor,
            policy: policy,
            now: now
        )
    }
}
