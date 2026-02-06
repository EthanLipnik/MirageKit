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
import MirageKit

#if os(macOS)
extension StreamContext {
    nonisolated func enqueueCapturedFrame(_ frame: CapturedFrame) {
        guard shouldEncodeFrames else { return }
        Task(priority: .userInitiated) { await self.recordCapturedFrame(frame) }
        if frame.info.isIdleFrame {
            Task(priority: .userInitiated) { await self.recordIdleSkip() }
            return
        }
        if frameInbox.enqueue(frame) {
            Task(priority: .userInitiated) { await self.processPendingFrames() }
        }
    }

    func recordCapturedFrame(_ frame: CapturedFrame) {
        captureIngressIntervalCount += 1
        lastCapturedFrameTime = CFAbsoluteTimeGetCurrent()
        lastCapturedFrame = frame
        lastCapturedDuration = frame.duration
        if startupBaseTime > 0, !startupFirstCaptureLogged {
            startupFirstCaptureLogged = true
            logStartupEvent("first captured frame")
        }
    }

    func recordIdleSkip() {
        idleSkippedCount += 1
    }

    func scheduleProcessingIfNeeded() {
        guard frameInbox.hasPending() else { return }
        if frameInbox.scheduleIfNeeded() {
            Task(priority: .userInitiated) { await processPendingFrames() }
        }
    }

    @discardableResult
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

    func resetPipelineStateForReconfiguration(reason: String) {
        if inFlightCount > 0 || isKeyframeEncoding || lastEncodeActivityTime > 0 { MirageLogger.stream("Resetting pipeline state for \(reason) (inFlight=\(inFlightCount))") }
        inFlightCount = 0
        lastEncodeActivityTime = 0
        isKeyframeEncoding = false
        needsEncoderReset = false
        pendingKeyframeReason = nil
        pendingKeyframeDeadline = 0
        pendingKeyframeRequiresFlush = false
        pendingKeyframeUrgent = false
        pendingKeyframeRequiresReset = false
        backpressureActive = false
        backpressureActiveSnapshot = false
        lastCapturedFrame = nil
        lastCapturedFrameTime = 0
        lastCapturedDuration = .invalid
        lastEncodedPresentationTime = .invalid
        lastSyntheticFrameTime = 0
        lastSyntheticLogTime = 0
        frameInbox.clear()
    }

    /// Process pending frames (encodes using HEVC and keeps only the most recent).
    func processPendingFrames() async {
        defer {
            frameInbox.markDrainComplete()
            Task { await self.logPipelineStatsIfNeeded() }
        }
        if isResizing || !shouldEncodeFrames {
            frameInbox.clear()
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

        while inFlightCount < maxInFlightFrames {
            guard let frame = frameInbox.takeNext() else { return }

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
                    MirageLogger.stream("Resetting stuck encoder before next frame")

                    do {
                        advanceEpoch(reason: "encoder reset")
                        await packetSender?.resetQueue(reason: "encoder reset")
                        try await encoder?.reset()
                        didResetEncoder = true
                        lastEncoderResetTime = now
                    } catch {
                        MirageLogger.error(.stream, "Encoder reset failed: \(error)")
                    }
                } else {
                    let remainingSeconds = (encoderResetCooldown - (now - lastEncoderResetTime))
                        .formatted(.number.precision(.fractionLength(1)))
                    MirageLogger.stream("Encoder reset skipped (cooldown active, \(remainingSeconds)s remaining)")
                }
                needsEncoderReset = false
            }

            let queueBytes = packetSender?.queuedBytesSnapshot() ?? 0
            await adjustQualityForQueue(queueBytes: queueBytes)

            var forceKeyframe = didResetEncoder
            if !forceKeyframe, let captureEngine {
                let shouldRequest = await captureEngine.consumePendingKeyframeRequest()
                if shouldRequest { forceKeyframeAfterCaptureRestart() }
            }
            if !forceKeyframe { forceKeyframe = shouldEmitPendingKeyframe(queueBytes: queueBytes) }

            if backpressureActive {
                if queueBytes <= queuePressureBytes {
                    backpressureActive = false
                    backpressureActiveSnapshot = false
                    MirageLogger.stream("Backpressure cleared (queue \(Int(Double(queueBytes) / 1024.0))KB)")
                } else {
                    backpressureDropIntervalCount += 1
                    droppedFrameCount += 1
                    logStreamStatsIfNeeded()
                    continue
                }
            } else if queueBytes > maxQueuedBytes, !forceKeyframe {
                backpressureActive = true
                backpressureActiveSnapshot = true
                backpressureDropIntervalCount += 1
                droppedFrameCount += 1
                let queuedKB = (Double(queueBytes) / 1024.0).rounded()
                MirageLogger.stream("Backpressure: pausing encode (queue \(Int(queuedKB))KB)")
                logStreamStatsIfNeeded()
                continue
            }

            if shouldQueueScheduledKeyframe(queueBytes: queueBytes) { queueKeyframe(reason: "Scheduled keyframe", checkInFlight: true) }

            let isIdleFrame = frame.info.isIdleFrame
            if isIdleFrame {
                idleSkippedCount += 1
                logStreamStatsIfNeeded()
                continue
            }

            setContentRect(frame.info.contentRect)

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
                    await encoder.prepareForKeyframe(quality: keyframeQuality(for: queueBytes))
                }
                let result = try await encoder.encodeFrame(frame, forceKeyframe: forceKeyframe)
                switch result {
                case .accepted:
                    encodeAcceptedIntervalCount += 1
                    if inFlightCount == 0 { lastEncodeActivityTime = encodeStartTime }
                    inFlightCount += 1
                    encodedFrameCount += 1
                    lastEncodedPresentationTime = frame.presentationTime
                    if forceKeyframe { isKeyframeEncoding = true }
                    if isIdleFrame { idleEncodedCount += 1 }
                case let .skipped(reason):
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
                encodeErrorIntervalCount += 1
                droppedFrameCount += 1
                MirageLogger.error(.stream, "Encode error: \(error)")
                continue
            }
            logStreamStatsIfNeeded()
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

        if frameInbox.hasPending(), inFlightCount < maxInFlightFrames { scheduleProcessingIfNeeded() }
    }

    func logStreamStatsIfNeeded() {
        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = now - lastStreamStatsLogTime
        guard lastStreamStatsLogTime == 0 || elapsed > 2.0 else { return }
        let inFlight = inFlightCount
        MirageLogger
            .stream(
                "Encode stats: encoded=\(encodedFrameCount), idleEncoded=\(idleEncodedCount), synthetic=\(syntheticFrameCount), idleSkipped=\(idleSkippedCount), inFlight=\(inFlight)"
            )
        if let metricsUpdateHandler, lastStreamStatsLogTime > 0 {
            let encodedFPS = Double(encodedFrameCount) / elapsed
            let idleEncodedFPS = Double(idleEncodedCount) / elapsed
            let message = StreamMetricsMessage(
                streamID: streamID,
                encodedFPS: encodedFPS,
                idleEncodedFPS: idleEncodedFPS,
                droppedFrames: droppedFrameCount,
                activeQuality: activeQuality,
                targetFrameRate: currentFrameRate
            )
            metricsUpdateHandler(message)
        }
        encodedFrameCount = 0
        idleEncodedCount = 0
        syntheticFrameCount = 0
        idleSkippedCount = 0
        lastStreamStatsLogTime = now
    }

    func logPipelineStatsIfNeeded() async {
        let now = CFAbsoluteTimeGetCurrent()
        guard lastPipelineStatsLogTime > 0 else {
            lastPipelineStatsLogTime = now
            return
        }
        let elapsed = now - lastPipelineStatsLogTime
        guard elapsed >= pipelineStatsInterval else { return }

        let metricsEnabled = MirageLogger.isEnabled(.metrics)
        let captureIngressFPS = Double(captureIngressIntervalCount) / elapsed
        let captureFPS = Double(captureIntervalCount) / elapsed
        let encodeAttemptFPS = Double(encodeAttemptIntervalCount) / elapsed
        let encodeFPS = Double(encodeAcceptedIntervalCount) / elapsed
        let encodeAvgMs = await encoder?.getAverageEncodeTimeMs() ?? 0
        let queueBytes = packetSender?.queuedBytesSnapshot() ?? 0
        let pendingCount = frameInbox.pendingCount()
        let captureGapMs = lastCapturedFrameTime > 0
            ? (now - lastCapturedFrameTime) * 1000
            : 0
        let syntheticFPS = Double(syntheticIntervalCount) / elapsed
        if metricsEnabled {
            let ingressText = captureIngressFPS.formatted(.number.precision(.fractionLength(1)))
            let captureText = captureFPS.formatted(.number.precision(.fractionLength(1)))
            let attemptText = encodeAttemptFPS.formatted(.number.precision(.fractionLength(1)))
            let encodeText = encodeFPS.formatted(.number.precision(.fractionLength(1)))
            let encodeAvgText = encodeAvgMs.formatted(.number.precision(.fractionLength(1)))
            let queueKB = Int((Double(queueBytes) / 1024.0).rounded())
            let captureGapText = captureGapMs.formatted(.number.precision(.fractionLength(1)))
            let syntheticText = syntheticFPS.formatted(.number.precision(.fractionLength(1)))

            MirageLogger.metrics(
                "Pipeline: ingress=\(ingressText)fps capture=\(captureText)fps drop=\(captureDroppedIntervalCount) " +
                    "bp=\(backpressureDropIntervalCount) encode=\(encodeText)fps attempt=\(attemptText)fps reject=\(encodeRejectedIntervalCount) " +
                    "skip(qFull=\(encodeSkipQueueFullIntervalCount) dim=\(encodeSkipDimensionIntervalCount) inactive=\(encodeSkipInactiveIntervalCount) " +
                    "session=\(encodeSkipNoSessionIntervalCount)) error=\(encodeErrorIntervalCount) " +
                    "synthetic=\(syntheticText)fps gap=\(captureGapText)ms inFlight=\(inFlightCount) buffer=\(pendingCount)/\(frameBufferDepth) " +
                    "queue=\(queueKB)KB encodeAvg=\(encodeAvgText)ms"
            )
        }

        await updateInFlightLimitIfNeeded(
            averageEncodeMs: encodeAvgMs,
            pendingCount: pendingCount
        )

        captureIngressIntervalCount = 0
        captureIntervalCount = 0
        captureDroppedIntervalCount = 0
        encodeAttemptIntervalCount = 0
        encodeAcceptedIntervalCount = 0
        encodeRejectedIntervalCount = 0
        encodeErrorIntervalCount = 0
        backpressureDropIntervalCount = 0
        encodeSkipQueueFullIntervalCount = 0
        encodeSkipDimensionIntervalCount = 0
        encodeSkipInactiveIntervalCount = 0
        encodeSkipNoSessionIntervalCount = 0
        syntheticIntervalCount = 0
        lastPipelineStatsLogTime = now
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

    func updateInFlightLimitIfNeeded(averageEncodeMs: Double, pendingCount: Int) async {
        guard maxInFlightFramesCap > 1 else { return }
        if useLowLatencyPipeline {
            let lowLatencyLimit = currentFrameRate >= 120 ? 2 : 1
            if maxInFlightFrames != lowLatencyLimit {
                maxInFlightFrames = lowLatencyLimit
                await encoder?.updateInFlightLimit(lowLatencyLimit)
                MirageLogger.metrics("In-flight depth forced to \(lowLatencyLimit) (low latency pipeline)")
            }
            return
        }

        let now = CFAbsoluteTimeGetCurrent()
        if lastInFlightAdjustmentTime > 0, now - lastInFlightAdjustmentTime < inFlightAdjustmentCooldown { return }

        let frameBudgetMs = 1000.0 / Double(max(1, currentFrameRate))
        var desired = maxInFlightFrames

        let increaseThreshold = latencyMode == .smoothest ? 1.02 : 1.10
        let decreaseThreshold = latencyMode == .smoothest ? 0.90 : 0.80
        if averageEncodeMs > frameBudgetMs * increaseThreshold || pendingCount > 0 { desired = min(maxInFlightFrames + 1, maxInFlightFramesCap) } else if averageEncodeMs < frameBudgetMs * decreaseThreshold, pendingCount == 0 {
            desired = max(maxInFlightFrames - 1, minInFlightFrames)
        }

        if desired < minInFlightFrames { desired = minInFlightFrames }

        guard desired != maxInFlightFrames else { return }
        maxInFlightFrames = desired
        lastInFlightAdjustmentTime = now
        await encoder?.updateInFlightLimit(desired)
        let budgetText = frameBudgetMs.formatted(.number.precision(.fractionLength(1)))
        let avgText = averageEncodeMs.formatted(.number.precision(.fractionLength(1)))
        MirageLogger.metrics("In-flight depth set to \(desired) (encode \(avgText)ms, budget \(budgetText)ms)")
    }

    func adjustQualityForQueue(queueBytes: Int) async {
        guard let encoder else { return }
        if qualityCeiling > compressionQualityCeiling { qualityCeiling = compressionQualityCeiling }
        if activeQuality > qualityCeiling {
            activeQuality = qualityCeiling
            await encoder.updateQuality(activeQuality)
        }
        let now = CFAbsoluteTimeGetCurrent()
        if lastQualityAdjustmentTime > 0, now - lastQualityAdjustmentTime < qualityAdjustmentCooldown { return }

        let averageEncodeMs = await encoder.getAverageEncodeTimeMs()
        if averageEncodeMs <= 0 { return }

        let frameBudgetMs = 1000.0 / Double(max(1, currentFrameRate))
        let encodeOverBudget = averageEncodeMs > frameBudgetMs * 1.05
        let queuePressured = queueBytes > queuePressureBytes
        let highPressure = queueBytes > maxQueuedBytes

        if encodeOverBudget || queuePressured {
            qualityUnderBudgetCount = 0
            qualityOverBudgetCount += 1
            let step = highPressure ? qualityDropStepHighPressure : qualityDropStep
            if qualityOverBudgetCount >= qualityDropThreshold {
                let next = max(qualityFloor, activeQuality - step)
                if next < activeQuality {
                    activeQuality = next
                    await encoder.updateQuality(activeQuality)
                    lastQualityAdjustmentTime = now
                    qualityOverBudgetCount = 0
                    let qualityText = activeQuality.formatted(.number.precision(.fractionLength(2)))
                    let avgText = averageEncodeMs.formatted(.number.precision(.fractionLength(1)))
                    MirageLogger.metrics("Quality down to \(qualityText) (encode \(avgText)ms, queue \(queueBytes / 1024)KB)")
                }
            }
        } else {
            qualityOverBudgetCount = 0
            qualityUnderBudgetCount += 1
            if qualityUnderBudgetCount >= qualityRaiseThreshold {
                let next = min(qualityCeiling, activeQuality + qualityRaiseStep)
                if next > activeQuality {
                    activeQuality = next
                    await encoder.updateQuality(activeQuality)
                    lastQualityAdjustmentTime = now
                    qualityUnderBudgetCount = 0
                    let qualityText = activeQuality.formatted(.number.precision(.fractionLength(2)))
                    let avgText = averageEncodeMs.formatted(.number.precision(.fractionLength(1)))
                    MirageLogger.metrics("Quality up to \(qualityText) (encode \(avgText)ms)")
                }
            }
        }
    }
}
#endif
