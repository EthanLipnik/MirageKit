//
//  StreamController+Decoder.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Stream controller extensions.
//

import Foundation
import CoreVideo

extension StreamController {
    // MARK: - Decoder Control

    /// Reset decoder for new session (e.g., after resize or reconnection)
    func resetForNewSession() async {
        // Drop any queued frames from the previous session to avoid BadData storms.
        stopFrameProcessingPipeline()
        await decoder.resetForNewSession()
        reassembler.reset()
        decodedFrameCount = 0
        currentFPS = 0
        fpsSampleTimes.removeAll()
        receivedFrameCount = 0
        currentReceiveFPS = 0
        receiveSampleTimes.removeAll()
        lastMetricsLogTime = 0
        lastMetricsDispatchTime = 0
        await startFrameProcessingPipeline()
    }

    func updateSampleTimes(_ sampleTimes: inout [CFAbsoluteTime], now: CFAbsoluteTime) -> Double {
        sampleTimes.append(now)
        let cutoff = now - 1.0
        if let firstValid = sampleTimes.firstIndex(where: { $0 >= cutoff }) {
            if firstValid > 0 {
                sampleTimes.removeFirst(firstValid)
            }
        } else {
            sampleTimes.removeAll()
        }
        return Double(sampleTimes.count)
    }

    func logMetricsIfNeeded(droppedFrames: UInt64) {
        let now = CFAbsoluteTimeGetCurrent()
        guard MirageLogger.isEnabled(.client) else { return }
        guard lastMetricsLogTime == 0 || now - lastMetricsLogTime > 2.0 else { return }
        let decodedText = currentFPS.formatted(.number.precision(.fractionLength(1)))
        let receivedText = currentReceiveFPS.formatted(.number.precision(.fractionLength(1)))
        MirageLogger.client("Client FPS: decoded=\(decodedText), received=\(receivedText), dropped=\(droppedFrames), stream=\(streamID)")
        lastMetricsLogTime = now
    }

    /// Get the reassembler for packet routing
    func getReassembler() -> FrameReassembler {
        reassembler
    }

}
