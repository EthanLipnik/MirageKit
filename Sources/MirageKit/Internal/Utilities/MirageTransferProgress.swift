//
//  MirageTransferProgress.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/11/26.
//

import Foundation
import Loom

/// Helpers for reducing Loom transfer progress streams into Mirage control-flow decisions.
package enum MirageTransferProgress {
    /// Returns the first terminal progress event, or the last observed event if the stream ends early.
    package static func terminalProgress(
        from stream: AsyncStream<LoomTransferProgress>
    ) async -> LoomTransferProgress? {
        var lastProgress: LoomTransferProgress?
        for await progress in stream {
            lastProgress = progress
            switch progress.state {
            case .completed, .cancelled, .failed, .declined:
                return progress
            case .offered, .waitingForAcceptance, .transferring:
                break
            }
        }
        return lastProgress
    }
}
