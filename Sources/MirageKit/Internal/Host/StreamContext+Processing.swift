//
//  StreamContext+Processing.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Frame processing and adaptive quality control.
//

import Foundation
import CoreMedia
import CoreVideo

#if os(macOS)
extension StreamContext {
    nonisolated func enqueueCapturedFrame(_ frame: CapturedFrame) {
        guard shouldEncodeFrames else { return }
        Task(priority: .userInitiated) { await self.recordCapturedFrame(frame) }
        if frameThrottle.shouldDrop(frame) {
            Task(priority: .userInitiated) { await self.recordCaptureDrop() }
            return
        }
        if frameInbox.enqueue(frame) {
            Task(priority: .userInitiated) { await self.processPendingFrames() }
        }
    }

    func recordCapturedFrame(_ frame: CapturedFrame) {
        lastCapturedFrameTime = CFAbsoluteTimeGetCurrent()
        lastCapturedFrame = frame
        lastCapturedDuration = frame.duration
    }

    func recordCaptureDrop() {
        captureDroppedIntervalCount += 1
        droppedFrameCount += 1
    }

    func startCadenceTaskIfNeeded() {
        cadenceTask?.cancel()
        cadenceTask = nil
    }

    func stopCadenceTask() {
        cadenceTask?.cancel()
        cadenceTask = nil
    }

    func emitCadenceFrameIfNeeded(frameInterval: TimeInterval) {}

    private func resolvedSyntheticDuration(fallback: CMTime) -> CMTime {
        if fallback.isValid, CMTimeCompare(fallback, .zero) == 1 {
            return fallback
        }
        let timescale = CMTimeScale(max(1, currentFrameRate))
        return CMTime(value: 1, timescale: timescale)
    }

    private func resolvedSyntheticPresentationTime(duration: CMTime, fallback: CMTime) -> CMTime {
        if lastEncodedPresentationTime.isValid {
            return CMTimeAdd(lastEncodedPresentationTime, duration)
        }
        if fallback.isValid {
            return CMTimeAdd(fallback, duration)
        }
        return CMClockGetTime(CMClockGetHostTimeClock())
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
        if inFlightCount > 0 || isKeyframeEncoding || lastEncodeActivityTime > 0 {
            MirageLogger.stream("Resetting pipeline state for \(reason) (inFlight=\(inFlightCount))")
        }
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
        lastCapturedFrame = nil
        lastCapturedFrameTime = 0
        lastCapturedDuration = .invalid
        lastEncodedPresentationTime = .invalid
        lastSyntheticFrameTime = 0
        lastSyntheticLogTime = 0
        frameThrottle.reset()
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
        if isKeyframeEncoding, !didResetStall {
            return
        }

        let captured = frameInbox.consumeEnqueuedCount()
        if captured > 0 {
            captureIntervalCount += captured
        }
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
                if shouldRequest {
                    forceKeyframeAfterCaptureRestart()
                }
            }
            if !forceKeyframe {
                forceKeyframe = shouldEmitPendingKeyframe(queueBytes: queueBytes)
            }

            if backpressureActive {
                if queueBytes <= queuePressureBytes {
                    backpressureActive = false
                    MirageLogger.stream("Backpressure cleared (queue \(Int(Double(queueBytes) / 1024.0))KB)")
                } else {
                    droppedFrameCount += 1
                    logStreamStatsIfNeeded()
                    continue
                }
            } else if queueBytes > maxQueuedBytes && !forceKeyframe {
                backpressureActive = true
                droppedFrameCount += 1
                let queuedKB = (Double(queueBytes) / 1024.0).rounded()
                MirageLogger.stream("Backpressure: pausing encode (queue \(Int(queuedKB))KB)")
                logStreamStatsIfNeeded()
                continue
            }

            if shouldQueueScheduledKeyframe(queueBytes: queueBytes) {
                queueKeyframe(reason: "Scheduled keyframe", checkInFlight: true)
            }

            let isIdleFrame = frame.info.isIdleFrame
            if isIdleFrame {
                let shouldEncodeIdle = shouldMaintainIdleFrames && queueBytes < queuePressureBytes
                if !shouldEncodeIdle {
                    idleSkippedCount += 1
                    logStreamStatsIfNeeded()
                    continue
                }
            }

            setContentRect(frame.info.contentRect)

            do {
                guard let encoder else {
                    continue
                }
                encodeAttemptIntervalCount += 1
                let encodeStartTime = CFAbsoluteTimeGetCurrent()
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
                let accepted = try await encoder.encodeFrame(frame, forceKeyframe: forceKeyframe)
                if accepted {
                    encodeAcceptedIntervalCount += 1
                    if inFlightCount == 0 {
                        lastEncodeActivityTime = encodeStartTime
                    }
                    inFlightCount += 1
                    encodedFrameCount += 1
                    lastEncodedPresentationTime = frame.presentationTime
                    if forceKeyframe {
                        isKeyframeEncoding = true
                    }
                    if isIdleFrame {
                        idleEncodedCount += 1
                    }
                } else if forceKeyframe {
                    encodeRejectedIntervalCount += 1
                    droppedFrameCount += 1
                    let now = CFAbsoluteTimeGetCurrent()
                    pendingKeyframeReason = "Deferred keyframe"
                    pendingKeyframeDeadline = max(pendingKeyframeDeadline, now + keyframeSettleTimeout)
                } else {
                    encodeRejectedIntervalCount += 1
                    droppedFrameCount += 1
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

        if frameInbox.hasPending() && inFlightCount < maxInFlightFrames {
            scheduleProcessingIfNeeded()
        }
    }

    func logStreamStatsIfNeeded() {
        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = now - lastStreamStatsLogTime
        guard lastStreamStatsLogTime == 0 || elapsed > 2.0 else { return }
        let inFlight = inFlightCount
        MirageLogger.stream("Encode stats: encoded=\(encodedFrameCount), idleEncoded=\(idleEncodedCount), synthetic=\(syntheticFrameCount), idleSkipped=\(idleSkippedCount), inFlight=\(inFlight)")
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
        guard MirageLogger.isEnabled(.metrics) else { return }
        let now = CFAbsoluteTimeGetCurrent()
        guard lastPipelineStatsLogTime > 0 else {
            lastPipelineStatsLogTime = now
            return
        }
        let elapsed = now - lastPipelineStatsLogTime
        guard elapsed >= pipelineStatsInterval else { return }

        let captureFPS = Double(captureIntervalCount) / elapsed
        let encodeAttemptFPS = Double(encodeAttemptIntervalCount) / elapsed
        let encodeFPS = Double(encodeAcceptedIntervalCount) / elapsed
        let captureText = captureFPS.formatted(.number.precision(.fractionLength(1)))
        let attemptText = encodeAttemptFPS.formatted(.number.precision(.fractionLength(1)))
        let encodeText = encodeFPS.formatted(.number.precision(.fractionLength(1)))
        let encodeAvgMs = await encoder?.getAverageEncodeTimeMs() ?? 0
        let encodeAvgText = encodeAvgMs.formatted(.number.precision(.fractionLength(1)))
        let queueBytes = packetSender?.queuedBytesSnapshot() ?? 0
        let queueKB = Int((Double(queueBytes) / 1024.0).rounded())
        let pendingCount = frameInbox.pendingCount()
        let captureGapMs = lastCapturedFrameTime > 0
            ? (now - lastCapturedFrameTime) * 1000
            : 0
        let captureGapText = captureGapMs.formatted(.number.precision(.fractionLength(1)))
        let syntheticFPS = Double(syntheticIntervalCount) / elapsed
        let syntheticText = syntheticFPS.formatted(.number.precision(.fractionLength(1)))

        MirageLogger.metrics(
            "Pipeline: capture=\(captureText)fps drop=\(captureDroppedIntervalCount) " +
            "encode=\(encodeText)fps attempt=\(attemptText)fps reject=\(encodeRejectedIntervalCount) error=\(encodeErrorIntervalCount) " +
            "synthetic=\(syntheticText)fps gap=\(captureGapText)ms inFlight=\(inFlightCount) buffer=\(pendingCount)/\(frameBufferDepth) " +
            "queue=\(queueKB)KB encodeAvg=\(encodeAvgText)ms"
        )

        await updateAdaptiveScaleIfNeeded(captureFPS: captureFPS)

        await updateInFlightLimitIfNeeded(
            averageEncodeMs: encodeAvgMs,
            pendingCount: pendingCount
        )

        captureIntervalCount = 0
        captureDroppedIntervalCount = 0
        encodeAttemptIntervalCount = 0
        encodeAcceptedIntervalCount = 0
        encodeRejectedIntervalCount = 0
        encodeErrorIntervalCount = 0
        syntheticIntervalCount = 0
        lastPipelineStatsLogTime = now
    }

    func updateAdaptiveScaleIfNeeded(captureFPS: Double) async {
        guard adaptiveScaleEnabled else { return }
        guard currentFrameRate >= 120 else { return }
        guard shouldEncodeFrames else { return }
        guard !isResizing else { return }

        let now = CFAbsoluteTimeGetCurrent()
        if lastAdaptiveScaleChangeTime > 0,
           now - lastAdaptiveScaleChangeTime < adaptiveScaleCooldown {
            return
        }

        let targetFPS = Double(currentFrameRate)
        let lowThreshold = targetFPS * adaptiveScaleLowThreshold
        let highThreshold = targetFPS * adaptiveScaleHighThreshold

        if captureFPS < lowThreshold {
            adaptiveScaleLowStreak += 1
            adaptiveScaleHighStreak = 0
        } else if captureFPS >= highThreshold {
            adaptiveScaleHighStreak += 1
            adaptiveScaleLowStreak = 0
        } else {
            adaptiveScaleLowStreak = max(0, adaptiveScaleLowStreak - 1)
            adaptiveScaleHighStreak = max(0, adaptiveScaleHighStreak - 1)
            return
        }

        if adaptiveScaleLowStreak >= adaptiveScaleDownSamples {
            let nextAdaptive = max(adaptiveScaleMin, adaptiveScale * adaptiveScaleDownStep)
            if nextAdaptive < adaptiveScale - 0.001 {
                adaptiveScale = nextAdaptive
                let effectiveScale = resolvedStreamScale(
                    for: baseCaptureSize,
                    requestedScale: requestedStreamScale * adaptiveScale,
                    logLabel: "Resolution cap"
                )
                if effectiveScale != streamScale {
                    lastAdaptiveScaleChangeTime = now
                    adaptiveScaleLowStreak = 0
                    adaptiveScaleHighStreak = 0
                    do {
                        try await applyStreamScale(effectiveScale, logLabel: "Adaptive scale down")
                        streamScaleUpdateHandler?(streamID)
                    } catch {
                        MirageLogger.error(.stream, "Adaptive scale down failed: \(error)")
                    }
                }
            }
            return
        }

        if adaptiveScaleHighStreak >= adaptiveScaleUpSamples {
            let nextAdaptive = min(1.0, adaptiveScale * adaptiveScaleUpStep)
            if nextAdaptive > adaptiveScale + 0.001 {
                adaptiveScale = nextAdaptive
                let effectiveScale = resolvedStreamScale(
                    for: baseCaptureSize,
                    requestedScale: requestedStreamScale * adaptiveScale,
                    logLabel: "Resolution cap"
                )
                if effectiveScale != streamScale {
                    lastAdaptiveScaleChangeTime = now
                    adaptiveScaleLowStreak = 0
                    adaptiveScaleHighStreak = 0
                    do {
                        try await applyStreamScale(effectiveScale, logLabel: "Adaptive scale up")
                        streamScaleUpdateHandler?(streamID)
                    } catch {
                        MirageLogger.error(.stream, "Adaptive scale up failed: \(error)")
                    }
                }
            }
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
        if lastInFlightAdjustmentTime > 0, now - lastInFlightAdjustmentTime < inFlightAdjustmentCooldown {
            return
        }

        let frameBudgetMs = 1000.0 / Double(max(1, currentFrameRate))
        var desired = maxInFlightFrames

        let increaseThreshold = latencyMode == .smoothest ? 1.02 : 1.10
        let decreaseThreshold = latencyMode == .smoothest ? 0.90 : 0.80
        if averageEncodeMs > frameBudgetMs * increaseThreshold || pendingCount > 0 {
            desired = min(maxInFlightFrames + 1, maxInFlightFramesCap)
        } else if averageEncodeMs < frameBudgetMs * decreaseThreshold && pendingCount == 0 {
            desired = max(maxInFlightFrames - 1, minInFlightFrames)
        }

        if desired < minInFlightFrames {
            desired = minInFlightFrames
        }

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
        guard latencyMode != .smoothest else { return }
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastQualityAdjustmentTime > qualityAdjustmentCooldown else { return }

        let frameBudgetMs = 1000.0 / Double(max(1, currentFrameRate))
        let isHighRefresh = currentFrameRate >= 120
        let averageEncodeMs = await encoder.getAverageEncodeTimeMs()
        let queuePressure = queueBytes >= queuePressureBytes
        let severePressure = queueBytes >= Int(Double(queuePressureBytes) * 1.5)
        let encodePressureMultiplier = isHighRefresh ? 1.55 : 1.35
        let heavyEncodePressureMultiplier = isHighRefresh ? 1.85 : 1.60
        let underBudgetMultiplier = isHighRefresh ? 0.65 : 0.75
        let encodePressure = averageEncodeMs > frameBudgetMs * encodePressureMultiplier
        let heavyEncodePressure = averageEncodeMs > frameBudgetMs * heavyEncodePressureMultiplier
        let underBudget = averageEncodeMs < frameBudgetMs * underBudgetMultiplier
        let queueClear = queueBytes < queuePressureBytes / 2

        if isHighRefresh {
            let scaleRoom = adaptiveScaleEnabled && adaptiveScale > adaptiveScaleMin + 0.01
            let demandDrop = queuePressure || severePressure || heavyEncodePressure
            if scaleRoom && !demandDrop {
                qualityOverBudgetCount = 0
                qualityUnderBudgetCount = 0
                return
            }
        }

        if queuePressure || encodePressure {
            qualityOverBudgetCount += 1
            qualityUnderBudgetCount = 0
        } else if queueClear && underBudget {
            qualityUnderBudgetCount += 1
            qualityOverBudgetCount = 0
        } else {
            qualityOverBudgetCount = max(0, qualityOverBudgetCount - 1)
            qualityUnderBudgetCount = max(0, qualityUnderBudgetCount - 1)
        }

        if qualityOverBudgetCount >= qualityDropThreshold, activeQuality > qualityFloor {
            let dropStep = (severePressure || heavyEncodePressure) ? qualityDropStepHighPressure : qualityDropStep
            activeQuality = max(qualityFloor, activeQuality - dropStep)
            await encoder.updateQuality(activeQuality)
            lastQualityAdjustmentTime = now
            qualityOverBudgetCount = 0
            let qualityText = activeQuality.formatted(.number.precision(.fractionLength(2)))
            let encodeText = averageEncodeMs.formatted(.number.precision(.fractionLength(1)))
            if queuePressure {
                let queueKB = Int(Double(queueBytes) / 1024.0)
                MirageLogger.stream("Encoder quality throttled to \(qualityText) (encode \(encodeText)ms, queue \(queueKB)KB)")
            } else {
                MirageLogger.stream("Encoder quality throttled to \(qualityText) (encode \(encodeText)ms)")
            }
            return
        }

        if qualityUnderBudgetCount >= qualityRaiseThreshold, activeQuality < qualityCeiling {
            activeQuality = min(qualityCeiling, activeQuality + qualityRaiseStep)
            await encoder.updateQuality(activeQuality)
            lastQualityAdjustmentTime = now
            qualityUnderBudgetCount = 0
            let qualityText = activeQuality.formatted(.number.precision(.fractionLength(2)))
            let encodeText = averageEncodeMs.formatted(.number.precision(.fractionLength(1)))
            MirageLogger.stream("Encoder quality restored to \(qualityText) (encode \(encodeText)ms)")
        }
    }
}
#endif
