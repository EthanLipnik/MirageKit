//
//  StreamController+Resize.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Stream controller extensions.
//

import CoreVideo
import Foundation
import MirageKit

extension StreamController {
    // MARK: - Resize Handling

    /// Handle drawable size change from Metal layer
    /// - Parameters:
    ///   - pixelSize: New drawable size in pixels
    ///   - screenBounds: Screen bounds in points
    ///   - scaleFactor: Screen scale factor
    func handleDrawableSizeChanged(
        _ pixelSize: CGSize,
        screenBounds: CGSize,
        scaleFactor: CGFloat
    )
    async {
        guard pixelSize.width > 0, pixelSize.height > 0 else { return }

        // Only enter resize mode after first frame
        if hasReceivedFirstFrame { await setResizeState(.awaiting(expectedSize: pixelSize)) }

        // Cancel pending debounce
        resizeDebounceTask?.cancel()

        // Debounce resize
        resizeDebounceTask = Task { [weak self] in
            guard let self else { return }

            do {
                try await Task.sleep(for: Self.resizeDebounceDelay)
            } catch {
                return // Cancelled
            }

            await processResizeEvent(pixelSize: pixelSize, screenBounds: screenBounds, scaleFactor: scaleFactor)
        }
    }

    /// Called when host confirms resize (sends new min size)
    func confirmResize(newMinSize: CGSize) async {
        if case .awaiting = resizeState {
            await setResizeState(.confirmed(finalSize: newMinSize))
            // Brief delay then return to idle
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(50))
                await self?.setResizeState(.idle)
            }
        }
    }

    /// Force clear resize state (e.g., when returning from background)
    func clearResizeState() async {
        resizeDebounceTask?.cancel()
        resizeDebounceTask = nil
        await setResizeState(.idle)
    }

    /// Request stream recovery (keyframe + reassembler reset)
    func requestRecovery(reason: RecoveryReason = .manualRecovery) async {
        MirageLogger.client("Starting stream recovery (\(reason.logLabel)) for stream \(streamID)")
        await clearResizeState()
        decodeRecoveryEscalationTimestamps.removeAll(keepingCapacity: false)
        MirageFrameCache.shared.clear(for: streamID)
        lastDecodedFrameTime = 0
        lastPresentedSequenceObserved = 0
        lastPresentedProgressTime = 0
        lastFreezeRecoveryTime = 0
        consecutiveFreezeRecoveries = 0
        stopFrameProcessingPipeline()
        await decoder.resetForNewSession()
        reassembler.reset()
        reassembler.enterKeyframeOnlyMode()
        startKeyframeRecoveryLoopIfNeeded()
        await startFrameProcessingPipeline()
        await requestKeyframeRecovery(reason: reason)
    }
}
