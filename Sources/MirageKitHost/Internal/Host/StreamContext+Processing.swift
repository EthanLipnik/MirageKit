//
//  StreamContext+Processing.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Frame processing and adaptive quality control.
//

import CoreVideo
import Foundation
import Network
import MirageKit

#if os(macOS)
extension StreamContext {
    func applySenderFrameBudgetRecoveryIfNeeded(
        packetTelemetry: StreamPacketSender.TelemetrySnapshot,
        frameBudgetMs: Double
    ) async {
        let queueBytes = max(0, packetTelemetry.queuedBytes)
        let nonKeyframeSendDelayMaxMs = max(
            packetTelemetry.nonKeyframeSendStartDelayMaxMs,
            packetTelemetry.nonKeyframeSendCompletionMaxMs
        )
        let lowQueuePressure = queueBytes <= queuePressureBytes
        let hasNonKeyframeDelay = nonKeyframeSendDelayMaxMs > 0
        let recoveryThresholdMs = max(
            1.0,
            frameBudgetMs * senderFrameBudgetDelayRecoveryMultiplier
        )
        let exceedsFrameBudget = hasNonKeyframeDelay &&
            nonKeyframeSendDelayMaxMs > recoveryThresholdMs

        if exceedsFrameBudget, lowQueuePressure {
            senderFrameBudgetDelayOverrunCount += 1
        } else {
            senderFrameBudgetDelayOverrunCount = 0
            return
        }

        guard senderFrameBudgetDelayOverrunCount >= senderFrameBudgetDelayOverrunThreshold else { return }
        senderFrameBudgetDelayOverrunCount = 0
        if usesSoftSenderDelaySmoothing {
            enterSoftFreshnessDrainIfNeeded(
                frameBudgetMs: frameBudgetMs,
                reason: "non-keyframe sender delay exceeded frame budget"
            )
            return
        }
        _ = await enterFreshnessBurstIfNeeded(
            queueBytes: queueBytes,
            reason: "non-keyframe sender delay exceeded frame budget"
        )
    }

    nonisolated func enqueueCapturedFrame(_ frame: CapturedFrame) {
        guard shouldEncodeFrames else {
            Task(priority: .userInitiated) { await self.handleCapturedFrameWhileStartupGated(frame) }
            return
        }
        if frame.info.isIdleFrame {
            Task(priority: .userInitiated) { await self.recordCaptureIngress(frame) }
            return
        }
        Task(priority: .userInitiated) { await self.recordCaptureIngress(frame) }
        if frameInbox.enqueue(frame) {
            Task(priority: .userInitiated) { await self.processPendingFrames() }
        }
    }

    func handleCapturedFrameWhileStartupGated(_ frame: CapturedFrame) {
        recordCaptureIngress(frame)
        guard startupFrameCachingEnabled else { return }
        cachedStartupFrame = frame
    }

    func recordCaptureIngress(_ frame: CapturedFrame) {
        captureIngressIntervalCount += 1
        lastCapturedFrameTime = CFAbsoluteTimeGetCurrent()
        lastCapturedFrame = frame
        if frame.info.isIdleFrame { idleSkippedCount += 1 }
        if startupBaseTime > 0, !startupFirstCaptureLogged {
            startupFirstCaptureLogged = true
            logStartupEvent("first captured frame")
        }
    }

    func scheduleProcessingIfNeeded() {
        guard frameInbox.hasPending else { return }
        if frameInbox.scheduleIfNeeded() {
            Task(priority: .userInitiated) { await processPendingFrames() }
        }
    }

    func resetStalledInFlightIfNeeded(label: String) -> Bool {
        guard inFlightCount > 0, lastEncodeActivityTime > 0 else { return false }
        let now = CFAbsoluteTimeGetCurrent()
        let elapsedMs = (now - lastEncodeActivityTime) * 1000
        guard elapsedMs > maxEncodeTimeMs else { return false }
        MirageLogger.stream("Encoder in-flight stalled for \(Int(elapsedMs))ms (\(label)), scheduling reset")
        inFlightCount = 0
        lastEncodeActivityTime = 0
        isKeyframeEncoding = false
        needsEncoderReset = true
        return true
    }

    func clearBackpressureState(queueBytes: Int? = nil, log: Bool = true) {
        let hadBackpressure = backpressureActive || backpressureActiveSnapshot || backpressureActivatedAt > 0
        backpressureActive = false
        backpressureActiveSnapshot = false
        backpressureActivatedAt = 0
        guard hadBackpressure, log, let queueBytes else { return }
        let queuedKB = Self.roundedKilobytes(queueBytes)
        MirageLogger.stream("Backpressure cleared (queue \(queuedKB)KB)")
    }

    /// Converts byte counts into rounded KiB values for compact diagnostics.
    nonisolated static func roundedKilobytes(_ bytes: Int) -> Int {
        Int((Double(max(0, bytes)) / 1024.0).rounded())
    }

    private func scheduleEncoderResetRetry(after delaySeconds: Double, reason: String) {
        guard shouldEncodeFrames else { return }
        guard delaySeconds > 0 else {
            scheduleProcessingIfNeeded()
            return
        }

        encoderResetRetryTask?.cancel()
        encoderResetRetryTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .seconds(delaySeconds))
            } catch {
                return
            }
            await retryEncoderResetIfStillNeeded(reason: reason)
        }
    }

    private func retryEncoderResetIfStillNeeded(reason: String) async {
        guard needsEncoderReset, shouldEncodeFrames, !isResizing else { return }
        encoderResetRetryTask = nil
        MirageLogger.stream("Retrying deferred encoder reset for stream \(streamID) (\(reason))")
        scheduleProcessingIfNeeded()
    }

    /// Process pending frames (encodes using HEVC and can switch to freshest-frame delivery).
    func processPendingFrames() async {
        defer {
            frameInbox.markDrainComplete()
            schedulePipelineStatsLog()
        }
        if isResizing || !shouldEncodeFrames {
            frameInbox.discardAll()
            return
        }

        let didResetStall = resetStalledInFlightIfNeeded(label: "processPendingFrames")
        if isKeyframeEncoding, !didResetStall { return }

        let captured = frameInbox.consumeEnqueuedCount()
        if captured > 0 { captureIntervalCount += captured }
        let dropped = frameInbox.consumeDroppedCount()
        if dropped > 0 {
            captureDroppedIntervalCount += dropped
            droppedFrameCount += dropped
        }

        // Capture admission drops can keep this loop alive without enqueued frames.
        // Re-check sender queue state so backpressure can clear even when we are not
        // currently processing a frame.
        let queueBytesSnapshot = packetSender?.queuedByteCount ?? 0
        if freshnessBurstActive {
            _ = await exitFreshnessBurstIfNeeded(
                queueBytes: queueBytesSnapshot,
                reason: "queue recovered"
            )
        } else if backpressureActive {
            if queueBytesSnapshot <= queuePressureBytes { clearBackpressureState(queueBytes: queueBytesSnapshot) }
        }
        expireSoftFreshnessDrainIfNeeded()

        while inFlightCount < maxInFlightFrames {
            let queueBytesBeforeDrain = packetSender?.queuedByteCount ?? 0
            let drainPolicy: StreamFrameInbox.DrainPolicy = if latencyBurstDrainsNewestFrames {
                .newest
            } else if queueBytesBeforeDrain > queuePressureBytes {
                .newest
            } else {
                .fifo
            }
            let drainResult = frameInbox.takeNext(policy: drainPolicy)
            if drainResult.droppedBeforeDelivery > 0 {
                let droppedCount = UInt64(drainResult.droppedBeforeDelivery)
                captureDroppedIntervalCount += droppedCount
                droppedFrameCount += droppedCount
                MirageLogger.metrics(
                    "Latency burst dropped \(drainResult.droppedBeforeDelivery) stale frames before encode for stream \(streamID)"
                )
            }
            guard let frame = drainResult.frame else { return }

            let encoderStuck = inFlightCount > 0 && lastEncodeActivityTime > 0 &&
                (CFAbsoluteTimeGetCurrent() - lastEncodeActivityTime) * 1000 > maxEncodeTimeMs

            if encoderStuck {
                let stuckTime = (CFAbsoluteTimeGetCurrent() - lastEncodeActivityTime) * 1000
                MirageLogger.stream("Encoder stuck for \(Int(stuckTime))ms, scheduling reset")
                inFlightCount = 0
                lastEncodeActivityTime = 0
                needsEncoderReset = true
            }

            let bufferSize = CGSize(
                width: CVPixelBufferGetWidth(frame.pixelBuffer),
                height: CVPixelBufferGetHeight(frame.pixelBuffer)
            )
            updateCaptureSizesIfNeeded(bufferSize)
            updateMotionState(with: frame.info)

            var didResetEncoder = false
            if needsEncoderReset {
                let now = CFAbsoluteTimeGetCurrent()
                if now - lastEncoderResetTime > encoderResetCooldown {
                    do {
                        MirageLogger.stream("Resetting stuck encoder before next frame")
                        markDiscontinuity(reason: "encoder reset", advanceEpoch: true)
                        await packetSender?.resetQueue(reason: "encoder reset")
                        try await encoder?.reset()
                        didResetEncoder = true
                        lastEncoderResetTime = now
                        needsEncoderReset = false
                        encoderResetRetryTask?.cancel()
                        encoderResetRetryTask = nil
                    } catch {
                        MirageLogger.error(.stream, error: error, message: "Encoder reset failed: ")
                        scheduleEncoderResetRetry(
                            after: max(encoderResetCooldown * 0.5, 0.25),
                            reason: "reset failed"
                        )
                        return
                    }
                } else {
                    let remainingDelay = max(0, encoderResetCooldown - (now - lastEncoderResetTime))
                    let remainingSeconds = remainingDelay
                        .formatted(.number.precision(.fractionLength(1)))
                    MirageLogger.stream("Encoder reset skipped (cooldown active, \(remainingSeconds)s remaining)")
                    scheduleEncoderResetRetry(after: remainingDelay, reason: "cooldown active")
                    return
                }
            }

            let queueBytes = packetSender?.queuedByteCount ?? 0
            let backpressureTriggerBytes = maxQueuedBytes

            var forceKeyframe = didResetEncoder
            if !forceKeyframe, let captureEngine {
                if let pendingReason = await captureEngine.consumePendingKeyframeRequest() {
                    switch pendingReason {
                    case .fallbackResume:
                        forceKeyframeAfterFallbackResume()
                    case let .captureRestart(restartStreak, shouldEscalateRecovery):
                        forceKeyframeAfterCaptureRestart(
                            restartStreak: restartStreak,
                            shouldEscalateRecovery: shouldEscalateRecovery
                        )
                    }
                }
            }
            if !forceKeyframe { forceKeyframe = shouldEmitPendingKeyframe(queueBytes: queueBytes) }

            if freshnessBurstActive {
                if await exitFreshnessBurstIfNeeded(
                    queueBytes: queueBytes,
                    reason: "queue recovered"
                ) {
                    await logStreamStatsIfNeeded()
                } else if queueBytes > backpressureTriggerBytes, !forceKeyframe {
                    backpressureDropIntervalCount += 1
                    droppedFrameCount += 1
                    await logStreamStatsIfNeeded()
                    continue
                }
            } else if queueBytes > backpressureTriggerBytes {
                _ = await enterFreshnessBurstIfNeeded(
                    queueBytes: queueBytes,
                    reason: "severe queue pressure"
                )
                await logStreamStatsIfNeeded()
                continue
            }

            if !freshnessBurstActive {
                await adjustQualityForQueue(queueBytes: queueBytes)
            }

            if queueBytes > backpressureTriggerBytes, freshnessBurstActive, !forceKeyframe {
                backpressureDropIntervalCount += 1
                droppedFrameCount += 1
                await logStreamStatsIfNeeded()
                continue
            }

            if shouldQueueScheduledKeyframe(queueBytes: queueBytes) {
                queueKeyframeIfPossible(reason: "Scheduled keyframe", checkInFlight: true)
            }

            let isIdleFrame = frame.info.isIdleFrame
            if isIdleFrame {
                idleSkippedCount += 1
                await logStreamStatsIfNeeded()
                continue
            }

            setContentRect(resolvedOutgoingContentRect(for: frame))
            enforceCaptureColorAttachments(on: frame.pixelBuffer)
            await applyTrafficLightCloneStampIfNeeded(frame: frame)

            do {
                guard let encoder else { continue }
                encodeAttemptIntervalCount += 1
                let encodeStartTime = CFAbsoluteTimeGetCurrent()
                if startupBaseTime > 0, !startupFirstEncodeLogged {
                    startupFirstEncodeLogged = true
                    logStartupEvent("first encode attempt")
                }
                if forceKeyframe {
                    if pendingKeyframeRequiresFlush {
                        pendingKeyframeRequiresFlush = false
                        if pendingKeyframeRequiresReset {
                            pendingKeyframeRequiresReset = false
                            await packetSender?.resetQueue(reason: "keyframe request")
                        } else {
                            await packetSender?.bumpGeneration(reason: "keyframe request")
                        }
                        await encoder.flush()
                    }
                    await encoder.prepareForKeyframe(quality: keyframeQuality)
                }
                // Pre-increment inFlightCount before the await suspension point.
                // The VT completion callback can fire during the await and schedule
                // finishEncoding on the actor; without this, finishEncoding sees
                // inFlightCount=0, skips its decrement, and the pipeline stalls.
                if inFlightCount == 0 { lastEncodeActivityTime = encodeStartTime }
                inFlightCount += 1
                if forceKeyframe { isKeyframeEncoding = true }

                let result = try await encoder.encodeFrame(frame, forceKeyframe: forceKeyframe)
                switch result {
                case .accepted:
                    encodeAcceptedIntervalCount += 1
                    encodedFrameCount += 1
                    if isIdleFrame { idleEncodedCount += 1 }
                case let .skipped(reason):
                    inFlightCount -= 1
                    if inFlightCount == 0 {
                        lastEncodeActivityTime = 0
                        if forceKeyframe { isKeyframeEncoding = false }
                    }
                    encodeRejectedIntervalCount += 1
                    droppedFrameCount += 1
                    recordEncoderSkip(reason)
                    if forceKeyframe {
                        let now = CFAbsoluteTimeGetCurrent()
                        pendingKeyframeReason = "Deferred keyframe"
                        pendingKeyframeDeadline = max(pendingKeyframeDeadline, now + keyframeSettleTimeout)
                    }
                }
            } catch {
                inFlightCount -= 1
                if inFlightCount == 0 {
                    lastEncodeActivityTime = 0
                    if forceKeyframe { isKeyframeEncoding = false }
                }
                encodeErrorIntervalCount += 1
                droppedFrameCount += 1
                MirageLogger.error(.stream, error: error, message: "Encode error: ")
                continue
            }
            await logStreamStatsIfNeeded()
        }
    }

    func finishEncoding() async {
        guard inFlightCount > 0 else { return }
        inFlightCount -= 1
        lastEncodeActivityTime = CFAbsoluteTimeGetCurrent()

        if inFlightCount == 0, isKeyframeEncoding {
            isKeyframeEncoding = false
            await encoder?.restoreBaseQualityIfNeeded()
        }

        if frameInbox.hasPending, inFlightCount < maxInFlightFrames { scheduleProcessingIfNeeded() }
    }

    func recordEncoderSkip(_ reason: EncodeSkipReason) {
        switch reason {
        case .queueFull:
            encodeSkipQueueFullIntervalCount += 1
        case .dimensionUpdate:
            encodeSkipDimensionIntervalCount += 1
        case .encoderInactive:
            encodeSkipInactiveIntervalCount += 1
        case .noSession:
            encodeSkipNoSessionIntervalCount += 1
        }
    }
}
#endif
