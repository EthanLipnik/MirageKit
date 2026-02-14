//
//  StreamController+Decoder.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Stream controller extensions.
//

import Foundation
import MirageKit

extension StreamController {
    // MARK: - Decoder Control

    /// Reset decoder for new session (e.g., after resize or reconnection)
    func resetForNewSession() async {
        // Drop any queued frames from the previous session to avoid BadData storms.
        MirageFrameCache.shared.clear(for: streamID)
        stopFrameProcessingPipeline()
        await decoder.resetForNewSession()
        reassembler.reset()
        metricsTracker.reset()
        lastMetricsLogTime = 0
        lastDecodedFrameTime = 0
        lastPresentedSequenceObserved = 0
        lastPresentedProgressTime = 0
        stopFreezeMonitor()
        await startFrameProcessingPipeline()
    }

    func logMetricsIfNeeded(decodedFPS: Double, receivedFPS: Double, droppedFrames: UInt64) {
        let now = currentTime()
        guard MirageLogger.isEnabled(.client) else { return }
        guard lastMetricsLogTime == 0 || now - lastMetricsLogTime > 2.0 else { return }
        let decodedText = decodedFPS.formatted(.number.precision(.fractionLength(1)))
        let receivedText = receivedFPS.formatted(.number.precision(.fractionLength(1)))
        MirageLogger
            .client(
                "Client FPS: decoded=\(decodedText), received=\(receivedText), dropped=\(droppedFrames), stream=\(streamID)"
            )
        lastMetricsLogTime = now
    }

    /// Get the reassembler for packet routing
    func getReassembler() -> FrameReassembler {
        reassembler
    }

    func updateDecodeSubmissionLimit(targetFrameRate: Int) async {
        await decoder.setDecodeSubmissionLimit(targetFrameRate: targetFrameRate)
    }
}
