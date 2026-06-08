//
//  StreamContext+Processing.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Frame processing and adaptive quality control.
//

import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageKit
import MirageKitClientPresentation
import MirageMedia
import MirageWire
import CoreVideo
import Foundation
import Network

#if os(macOS)
extension StreamContext {
    nonisolated func enqueueCapturedFrame(_ frame: CapturedFrame) {
        guard shouldEncodeFrames else {
            Task(priority: .userInitiated) { await self.handleCapturedFrameWhileStartupGated(frame) }
            return
        }
        if frame.info.isIdleFrame {
            Task(priority: .userInitiated) { await self.recordCaptureIngress(frame) }
            guard shouldAdmitIdleQualityProbeFrame else { return }
        } else {
            Task(priority: .userInitiated) { await self.recordCaptureIngress(frame) }
        }
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
        let now = CFAbsoluteTimeGetCurrent()
        lastCapturedFrameTime = now
        lastCapturedFrame = frame
        if frame.info.isIdleFrame { idleSkippedCount += 1 }
        if !frame.info.isIdleFrame { lastNonIdleCapturedFrameTime = now }
        if useMosaic {
            updateMosaicDirtyTileState(frame: frame, now: now)
        }
        updateIdleQualityProbeAdmissionHint(now: now)
        if startupBaseTime > 0, !startupFirstCaptureLogged {
            startupFirstCaptureLogged = true
            logStartupEvent("first captured frame")
        }
    }

    func scheduleProcessingIfNeeded() {
        guard shouldEncodeFrames else { return }
        guard frameInbox.hasPending else { return }
        if frameInbox.scheduleIfNeeded() {
            Task(priority: .userInitiated) { await processPendingFrames() }
        }
    }

    func scheduleProcessingAfterFrameInboxEnqueue(_ shouldScheduleDrain: Bool) {
        guard shouldScheduleDrain else {
            scheduleProcessingIfNeeded()
            return
        }
        guard shouldEncodeFrames else {
            _ = frameInbox.markDrainComplete()
            return
        }
        Task(priority: .userInitiated) { await processPendingFrames() }
    }

    func resetStalledInFlightIfNeeded(label: String) -> Bool {
        guard inFlightCount > 0, lastEncodeActivityTime > 0 else { return false }
        let now = CFAbsoluteTimeGetCurrent()
        let elapsedMs = (now - lastEncodeActivityTime) * 1000
        guard elapsedMs > maxEncodeTimeMs else { return false }
        MirageLogger.stream("Encoder in-flight stalled for \(Int(elapsedMs))ms (\(label)), scheduling reset")
        inFlightCount = 0
        encoderInFlightCountSnapshot = inFlightCount
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

    private func logEncodeStageIfNeeded(
        frame: CapturedFrame,
        encodeStartTime: CFAbsoluteTime,
        drainDropped: Int,
        queueBytes: Int,
        forceKeyframe: Bool
    ) {
        guard encodeStartTime - encodeStageLastLogTime >= 0.5 else { return }
        encodeStageLastLogTime = encodeStartTime

        let captureAgeMs = max(0, (encodeStartTime - frame.captureTime) * 1_000)
        let pending = frameInbox.pendingSnapshot
        let policy = activeFrameFreshnessPolicy
        let inputActive = inputIsActive(now: encodeStartTime, policy: policy)
        let sourceStill = sourceIsStill(now: encodeStartTime, policy: policy)
        let targetBitrate = currentTargetBitrateBps ?? encoderConfig.bitrate ?? requestedTargetBitrate ?? 0
        let targetMbps = Double(targetBitrate) / 1_000_000.0
        let qualityText = activeQuality.formatted(.number.precision(.fractionLength(2)))
        let captureAgeText = captureAgeMs.formatted(.number.precision(.fractionLength(1)))
        let dirtyText = frame.info.dirtyPercentage.formatted(.number.precision(.fractionLength(1)))
        let targetText = targetMbps.formatted(.number.precision(.fractionLength(1)))
        MirageLogger.metrics(
            "Host encode stage stream \(streamID): " +
                "captureAge=\(captureAgeText)ms dirty=\(dirtyText)% idle=\(frame.info.isIdleFrame) " +
                "inputActive=\(inputActive) sourceStill=\(sourceStill) " +
                "inFlight=\(inFlightCount)/\(maxInFlightFrames) inbox=\(pending.pending)/\(pending.capacity) " +
                "drainDropped=\(drainDropped) queueKB=\(Self.roundedKilobytes(queueBytes)) " +
            "quality=\(qualityText) target=\(targetText)Mbps keyframe=\(forceKeyframe)"
        )
    }

    private func recordEncodeStartCaptureAge(
        frame: CapturedFrame,
        encodeStartTime: CFAbsoluteTime
    ) {
        let captureAgeMs = max(0, (encodeStartTime - frame.captureTime) * 1_000)
        latestEncodeStartCaptureAgeMs = captureAgeMs
        worstEncodeStartCaptureAgeMs = max(worstEncodeStartCaptureAgeMs, captureAgeMs)
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
            let canDrainPendingFrames = !isResizing &&
                shouldEncodeFrames &&
                !needsEncoderReset &&
                !isKeyframeEncoding &&
                inFlightCount < maxInFlightFrames
            let shouldResumeDrain = frameInbox.markDrainComplete(scheduleIfPending: canDrainPendingFrames)
            schedulePipelineStatsLog()
            if shouldResumeDrain {
                Task(priority: .userInitiated) { await self.processPendingFrames() }
            }
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
            let encoderAverageEncodeMs = await encoder?.averageEncodeTimeMs ?? encoderAverageEncodeMsSnapshot
            encoderAverageEncodeMsSnapshot = encoderAverageEncodeMs
            encoderInFlightCountSnapshot = inFlightCount
            let pendingBeforeDrain = frameInbox.pendingSnapshot
            let encoderLagSnapshot = HostCaptureAdmissionPolicy.EncoderLagSnapshot(
                averageEncodeMs: encoderAverageEncodeMs,
                inFlightCount: inFlightCount,
                frameRate: currentFrameRate
            )
            let shouldDrainNewestForEncoderLag = HostCaptureAdmissionPolicy.shouldDrainNewestBeforeEncode(
                latencyMode: latencyMode,
                hostBufferingPolicy: hostBufferingPolicy,
                pendingFrameCount: pendingBeforeDrain.pending,
                frameCapacity: pendingBeforeDrain.capacity,
                encoderLag: encoderLagSnapshot
            )
            let drainPolicy: StreamFrameInbox.DrainPolicy = if latencyBurstDrainsNewestFrames {
                .newest
            } else if queueBytesBeforeDrain > queuePressureBytes {
                .newest
            } else if shouldDrainNewestForEncoderLag {
                .newest
            } else {
                .fifo
            }
            let drainResult = frameInbox.takeNext(policy: drainPolicy)
            if drainResult.droppedBeforeDelivery > 0 {
                let droppedCount = UInt64(drainResult.droppedBeforeDelivery)
                captureDroppedIntervalCount += droppedCount
                droppedFrameCount += droppedCount
                let dropReason = shouldDrainNewestForEncoderLag ? "Encoder lag" : "Latency burst"
                MirageLogger.metrics(
                    "\(dropReason) dropped \(drainResult.droppedBeforeDelivery) stale frames before encode for stream \(streamID)"
                )
            }
            guard let frame = drainResult.frame else { return }

            let encoderStuck = inFlightCount > 0 && lastEncodeActivityTime > 0 &&
                (CFAbsoluteTimeGetCurrent() - lastEncodeActivityTime) * 1000 > maxEncodeTimeMs

            if encoderStuck {
                let stuckTime = (CFAbsoluteTimeGetCurrent() - lastEncodeActivityTime) * 1000
                MirageLogger.stream("Encoder stuck for \(Int(stuckTime))ms, scheduling reset")
                inFlightCount = 0
                encoderInFlightCountSnapshot = inFlightCount
                lastEncodeActivityTime = 0
                needsEncoderReset = true
            }

            let bufferSize = CGSize(
                width: CVPixelBufferGetWidth(frame.pixelBuffer),
                height: CVPixelBufferGetHeight(frame.pixelBuffer)
            )
            updateCaptureSizesIfNeeded(bufferSize)

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
                    case let .captureRestart(restartStreak, shouldEscalateRecovery):
                        forceKeyframeAfterCaptureRestart(
                            restartStreak: restartStreak,
                            shouldEscalateRecovery: shouldEscalateRecovery
                        )
                    }
                }
            }
            if !forceKeyframe { forceKeyframe = shouldEmitPendingKeyframe(queueBytes: queueBytes) }

            let frameAdmissionTime = CFAbsoluteTimeGetCurrent()
            if !forceKeyframe, shouldSkipPFrameBeforeReservationForFreshness(now: frameAdmissionTime) {
                backpressureDropIntervalCount += 1
                droppedFrameCount += 1
                await logStreamStatsIfNeeded()
                continue
            }

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

            if queueBytes > backpressureTriggerBytes, freshnessBurstActive, !forceKeyframe {
                backpressureDropIntervalCount += 1
                droppedFrameCount += 1
                await logStreamStatsIfNeeded()
                continue
            }

            if shouldQueueScheduledKeyframe(queueBytes: queueBytes) {
                queueKeyframeIfPossible(
                    reason: "Scheduled keyframe",
                    checkInFlight: true,
                    countsAgainstRecoveryBudget: false
                )
            }

            if frameChainSuppressesPFrames, !forceKeyframe {
                droppedFrameCount += 1
                await logStreamStatsIfNeeded()
                continue
            }

            let isIdleFrame = frame.info.isIdleFrame
            if isIdleFrame {
                if forceKeyframe {
                    shouldAdmitIdleQualityProbeFrame = false
                } else if shouldEncodeStillQualityProbeFrame(now: frameAdmissionTime) {
                    lastStillQualityProbeEncodeTime = frameAdmissionTime
                    shouldAdmitIdleQualityProbeFrame = false
                } else {
                    updateIdleQualityProbeAdmissionHint(now: frameAdmissionTime)
                    await logStreamStatsIfNeeded()
                    continue
                }
            }

            setContentRect(resolvedOutgoingContentRect(for: frame))
            enforceCaptureColorAttachments(on: frame.pixelBuffer)
            await applyTrafficLightCloneStampIfNeeded(frame: frame)

            if streamKind == .desktop, useMosaic {
                do {
                    encodeAttemptIntervalCount += 1
                    let encodeStartTime = CFAbsoluteTimeGetCurrent()
                    recordEncodeStartCaptureAge(frame: frame, encodeStartTime: encodeStartTime)
                    logEncodeStageIfNeeded(
                        frame: frame,
                        encodeStartTime: encodeStartTime,
                        drainDropped: drainResult.droppedBeforeDelivery,
                        queueBytes: queueBytes,
                        forceKeyframe: forceKeyframe
                    )
                    if startupBaseTime > 0, !startupFirstEncodeLogged {
                        startupFirstEncodeLogged = true
                        logStartupEvent("first encode attempt")
                    }
                    if try await encodeMosaicMediaUnits(
                        from: frame,
                        forceKeyframe: forceKeyframe,
                        isIdleFrame: isIdleFrame,
                        encodeStartTime: encodeStartTime
                    ) {
                        await logStreamStatsIfNeeded()
                        continue
                    }
                    await logStreamStatsIfNeeded()
                    continue
                } catch {
                    encodeErrorIntervalCount += 1
                    droppedFrameCount += 1
                    MirageLogger.error(.stream, error: error, message: "Mosaic encode error: ")
                    continue
                }
            }

            do {
                guard let encoder else { continue }
                encodeAttemptIntervalCount += 1
                let encodeStartTime = CFAbsoluteTimeGetCurrent()
                recordEncodeStartCaptureAge(frame: frame, encodeStartTime: encodeStartTime)
                logEncodeStageIfNeeded(
                    frame: frame,
                    encodeStartTime: encodeStartTime,
                    drainDropped: drainResult.droppedBeforeDelivery,
                    queueBytes: queueBytes,
                    forceKeyframe: forceKeyframe
                )
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
                    await encoder.prepareForKeyframe(
                        quality: pendingEmergencyKeyframeQuality ?? keyframeQuality
                    )
                }
                // Pre-increment inFlightCount before the await suspension point.
                // The VT completion callback can fire during the await and schedule
                // finishEncoding on the actor; without this, finishEncoding sees
                // inFlightCount=0, skips its decrement, and the pipeline stalls.
                if inFlightCount == 0 { lastEncodeActivityTime = encodeStartTime }
                inFlightCount += 1
                encoderInFlightCountSnapshot = inFlightCount
                if forceKeyframe { isKeyframeEncoding = true }

                let result = try await encoder.encodeFrame(frame, forceKeyframe: forceKeyframe)
                switch result {
                case .accepted:
                    encodeAcceptedIntervalCount += 1
                    encodedFrameCount += 1
                    if isIdleFrame { idleEncodedCount += 1 }
                case let .skipped(reason):
                    inFlightCount -= 1
                    encoderInFlightCountSnapshot = inFlightCount
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
                encoderInFlightCountSnapshot = inFlightCount
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

    private func encodeMosaicMediaUnits(
        from frame: CapturedFrame,
        forceKeyframe: Bool,
        isIdleFrame: Bool,
        encodeStartTime: CFAbsoluteTime
    ) async throws -> Bool {
        let units = mosaicMediaUnitsForEncoding(forceKeyframe: forceKeyframe)
        guard !units.isEmpty else { return false }
        let activeUnits = mosaicActiveMediaUnits()
        let preparedUnits = try await mosaicCodecUnitEncoderPool.synchronize(
            units: units,
            activeUnits: activeUnits,
            configuration: encoderConfig,
            latencyMode: latencyMode,
            mediaPathProfile: mediaPathProfile,
            inFlightLimit: maxInFlightFrames,
            maximizePowerEfficiencyEnabled: encoderLowPowerEnabled,
            factory: videoEncoderFactoryBackend
        )
        guard !preparedUnits.isEmpty else { return false }

        if forceKeyframe, pendingKeyframeRequiresFlush {
            pendingKeyframeRequiresFlush = false
            if pendingKeyframeRequiresReset {
                pendingKeyframeRequiresReset = false
                await packetSender?.resetQueue(reason: "mosaic keyframe request")
            } else {
                await packetSender?.bumpGeneration(reason: "mosaic keyframe request")
            }
            mosaicEncodedDependencyTracker.reset()
            for preparedUnit in preparedUnits {
                await preparedUnit.encoder.flush()
            }
        }

        var acceptedCount = 0
        for preparedUnit in preparedUnits {
            guard let encodedChainUnit = mosaicEncodedDependencyTracker.workItemForEncoding(
                preparedUnit.workItem,
                forceKeyframe: forceKeyframe
            ) else {
                continue
            }
            let workItem = encodedChainUnit.workItem

            guard let croppedFrame = mosaicMediaUnitCropper.croppedFrame(
                from: frame,
                unit: workItem
            ) else {
                mosaicEncodedDependencyTracker.noteEncodingAbandoned(workItem)
                encodeRejectedIntervalCount += 1
                droppedFrameCount += 1
                continue
            }

            let shouldForceUnitKeyframe = encodedChainUnit.shouldForceKeyframe
            let unitQuality = mosaicTileQualityGovernor.quality(
                for: workItem,
                activeQuality: activeQuality,
                configuredCeiling: configuredQualityCeiling,
                compressionCeiling: compressionQualityCeiling
            )
            await startMosaicUnitEncoder(
                preparedUnit.encoder,
                workItem: workItem,
                baseFrameFlagsSnapshot: baseFrameFlags
            )
            await preparedUnit.encoder.updateQuality(unitQuality)
            if shouldForceUnitKeyframe {
                await preparedUnit.encoder.prepareForKeyframe(
                    quality: min(pendingEmergencyKeyframeQuality ?? keyframeQuality, unitQuality)
                )
            }

            if inFlightCount == 0 { lastEncodeActivityTime = encodeStartTime }
            inFlightCount += 1
            encoderInFlightCountSnapshot = inFlightCount
            if shouldForceUnitKeyframe { isKeyframeEncoding = true }

            let result: EncodeAdmission
            do {
                result = try await preparedUnit.encoder.encodeFrame(
                    croppedFrame,
                    forceKeyframe: shouldForceUnitKeyframe
                )
            } catch {
                mosaicEncodedDependencyTracker.noteEncodingAbandoned(workItem)
                inFlightCount -= 1
                encoderInFlightCountSnapshot = inFlightCount
                if inFlightCount == 0 {
                    lastEncodeActivityTime = 0
                    if shouldForceUnitKeyframe { isKeyframeEncoding = false }
                }
                encodeErrorIntervalCount += 1
                droppedFrameCount += 1
                MirageLogger.error(.stream, error: error, message: "Mosaic encode error: ")
                continue
            }
            switch result {
            case .accepted:
                acceptedCount += 1
                encodeAcceptedIntervalCount += 1
                encodedFrameCount += 1
                if isIdleFrame { idleEncodedCount += 1 }
            case let .skipped(reason):
                mosaicEncodedDependencyTracker.noteEncodingAbandoned(workItem)
                inFlightCount -= 1
                encoderInFlightCountSnapshot = inFlightCount
                if inFlightCount == 0 {
                    lastEncodeActivityTime = 0
                    if shouldForceUnitKeyframe { isKeyframeEncoding = false }
                }
                encodeRejectedIntervalCount += 1
                droppedFrameCount += 1
                recordEncoderSkip(reason)
            }
        }
        return acceptedCount > 0
    }

    private func mosaicMediaUnitsForEncoding(
        forceKeyframe: Bool
    ) -> [StreamContextMosaicMediaUnitWorkItem] {
        guard forceKeyframe,
              let tilePlan = latestMosaicTilePlan else {
            return latestMosaicMediaUnitWorkItems
        }
        return mosaicActiveMediaUnits(plan: tilePlan)
    }

    private func mosaicActiveMediaUnits(
        plan: MirageMosaicTilePlan? = nil
    ) -> [StreamContextMosaicMediaUnitWorkItem] {
        let tilePlan = plan ?? latestMosaicTilePlan
        guard let tilePlan else {
            return latestMosaicMediaUnitWorkItems
        }
        return mosaicMediaUnitPlanner.plannedUnits(
            plan: tilePlan,
            summary: latestMosaicDirtyTileSummary,
            includeCleanUnits: true,
            qualityRefreshTileIDs: latestMosaicQualityRefreshTileIDs
        )
    }

    func finishEncoding() async {
        guard inFlightCount > 0 else { return }
        inFlightCount -= 1
        encoderInFlightCountSnapshot = inFlightCount
        encoderAverageEncodeMsSnapshot = await encoder?.averageEncodeTimeMs ?? encoderAverageEncodeMsSnapshot
        lastEncodeActivityTime = CFAbsoluteTimeGetCurrent()

        if inFlightCount == 0, isKeyframeEncoding {
            isKeyframeEncoding = false
            if useMosaic {
                await mosaicCodecUnitEncoderPool.restoreBaseQualityForAll()
            } else {
                await encoder?.restoreBaseQualityIfNeeded()
            }
        }

        let canScheduleMore = useMosaic ? inFlightCount == 0 : inFlightCount < maxInFlightFrames
        if frameInbox.hasPending, canScheduleMore { scheduleProcessingIfNeeded() }
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

    private func shouldSkipPFrameBeforeReservationForFreshness(now: CFAbsoluteTime) -> Bool {
        guard useLowLatencyPipeline,
              frameChainState == .normal,
              let packetSender else {
            return false
        }
        let snapshot = packetSender.freshnessSnapshot(now: now)
        let policy = activeFrameFreshnessPolicy
        let inputActive = inputIsActive(now: now, policy: policy)
        let sourceStill = sourceIsStill(now: now, policy: policy)
        guard policy.shouldHoldPFrameReservation(
            unstartedPFrameCount: snapshot.unstartedPFrameCount,
            oldestUnstartedPFrameAgeMs: snapshot.oldestUnstartedPFrameAgeMs,
            oldestUnstartedPFrameLatenessMs: snapshot.oldestUnstartedPFrameLatenessMs,
            lateReservedPFrameStreak: snapshot.lateReservedPFrameStreak,
            inputActive: inputActive,
            sourceStill: sourceStill
        ) else { return false }
        if now - senderFreshnessLastLogTime >= 0.5 {
            senderFreshnessLastLogTime = now
            let oldestAge = snapshot.oldestUnstartedPFrameAgeMs.formatted(.number.precision(.fractionLength(1)))
            let oldestLate = snapshot.oldestUnstartedPFrameLatenessMs.formatted(.number.precision(.fractionLength(1)))
            MirageLogger.metrics(
                "event=sender_freshness_pre_reservation_skip stream=\(streamID) " +
                    "pendingP=\(snapshot.unstartedPFrameCount) oldestAgeMs=\(oldestAge) " +
                    "oldestLateMs=\(oldestLate) lateStreak=\(snapshot.lateReservedPFrameStreak) " +
                    "queuedBytes=\(snapshot.queuedBytes) inputActive=\(inputActive) sourceStill=\(sourceStill)"
            )
        }
        return true
    }

    private func updateMosaicDirtyTileState(frame: CapturedFrame, now: CFAbsoluteTime) {
        let logicalSize = mosaicLogicalSize(for: frame)
        guard !logicalSize.isEmpty else { return }
        let frameNumber = UInt32(truncatingIfNeeded: captureIngressIntervalCount)
        let semanticSnapshot = mosaicSemanticSnapshotCache.snapshot(
            logicalSize: logicalSize,
            captureBounds: mosaicSemanticCaptureBounds(for: frame, logicalSize: logicalSize)
        )
        guard let result = mosaicDirtyTileTracker.record(StreamContextMosaicDirtyTileFrame(
            logicalSize: logicalSize,
            codec: encoderConfig.codec,
            isIdleFrame: frame.info.isIdleFrame,
            frameNumber: frameNumber,
            semanticCandidates: semanticSnapshot.candidates,
            isTransientSystemState: semanticSnapshot.isTransientSystemState
        ), signaturesFor: { plan in
            StreamContextMosaicTileSignatureSampler.signatures(
                in: frame.pixelBuffer,
                for: plan
            )
        }, forcedRefreshTileIDsFor: { plan in
            self.mosaicQualityRefreshTileIDs(for: plan, frame: frame, now: now)
        }) else {
            return
        }
        let qualityRefreshTileIDs = Set(result.classification.decisions.compactMap { decision in
            decision.reasons.contains(.forcedRefresh) ? decision.tileID : nil
        })
        latestMosaicTilePlan = result.plan
        latestMosaicDirtyTileSummary = result.classification.summary
        latestMosaicQualityRefreshTileIDs = qualityRefreshTileIDs
        latestMosaicMediaUnitWorkItems = mosaicMediaUnitPlanner.plannedUnits(
            plan: result.plan,
            summary: result.classification.summary,
            qualityRefreshTileIDs: qualityRefreshTileIDs
        )
        dispatchMosaicTilePlanIfNeeded()
        logMosaicDirtyTileStateIfNeeded(result, frame: frame, now: now)
    }

    private func mosaicLogicalSize(for frame: CapturedFrame) -> MiragePixelSize {
        let frameSize = CGSize(
            width: CVPixelBufferGetWidth(frame.pixelBuffer),
            height: CVPixelBufferGetHeight(frame.pixelBuffer)
        )
        if frameSize.width > 0, frameSize.height > 0 {
            return MiragePixelSize(rounded: frameSize)
        }
        return MiragePixelSize(rounded: currentEncodedSize)
    }

    private func mosaicSemanticCaptureBounds(
        for frame: CapturedFrame,
        logicalSize: MiragePixelSize
    ) -> CGRect {
        if let virtualDisplayContext {
            let scale = max(1.0, virtualDisplayContext.scaleFactor)
            let logicalResolution = SharedVirtualDisplayManager.logicalResolution(
                for: virtualDisplayContext.resolution,
                scaleFactor: scale
            )
            let displayBounds = virtualDisplayBackend.displayBounds(
                virtualDisplayContext.displayID,
                knownResolution: logicalResolution
            ).standardized
            let displayVisibleBounds = virtualDisplayBackend.displayVisibleBounds(
                virtualDisplayContext.displayID,
                knownBounds: displayBounds
            ).standardized
            let visibleBounds = virtualDisplayVisibleBounds.standardized
            if !displayVisibleBounds.isEmpty {
                let clippedVisibleBounds = displayVisibleBounds.intersection(displayBounds).standardized
                if !clippedVisibleBounds.isEmpty { return clippedVisibleBounds }
            }
            if !visibleBounds.isEmpty { return visibleBounds }
            if !displayBounds.isEmpty { return displayBounds }
        }
        let contentRect = frame.info.contentRect.standardized
        if !contentRect.isEmpty { return contentRect }
        return CGRect(
            x: 0,
            y: 0,
            width: CGFloat(logicalSize.width),
            height: CGFloat(logicalSize.height)
        )
    }

    private func logMosaicDirtyTileStateIfNeeded(
        _ result: StreamContextMosaicDirtyTileTrackingResult,
        frame: CapturedFrame,
        now: CFAbsoluteTime
    ) {
        guard MirageSteadyStateDiagnostics.isEnabled,
              MirageLogger.isEnabled(.metrics),
              now - lastMosaicDirtyTileLogTime >= 1.0 else {
            return
        }
        lastMosaicDirtyTileLogTime = now
        let dirtyTileIDs = result.classification.summary.dirtyTileIDs
            .prefix(6)
            .map(\.rawValue)
            .joined(separator: ",")
        let dirtyText = frame.info.dirtyPercentage.formatted(.number.precision(.fractionLength(1)))
        MirageLogger.metrics(
            "Mosaic dirty state stream \(streamID): " +
                "plan=\(result.plan.kind.rawValue) epoch=\(result.plan.epoch) " +
                "dirtyTiles=\(result.dirtyTileCount)/\(result.tileCount) " +
                "mediaUnits=\(latestMosaicMediaUnitWorkItems.count) " +
                "captureDirty=\(dirtyText)% idle=\(frame.info.isIdleFrame) " +
                "sample=[\(dirtyTileIDs)]"
        )
    }

    private func mosaicQualityRefreshTileIDs(
        for plan: MirageMosaicTilePlan,
        frame: CapturedFrame,
        now: CFAbsoluteTime
    ) -> Set<MirageMosaicTileID> {
        guard runtimeQualityAdjustmentEnabled,
              activeQuality + 0.005 < configuredQualityCeiling,
              !plan.tiles.isEmpty else {
            return []
        }
        guard frame.info.isSynthetic || shouldAdmitIdleQualityProbeFrame else { return [] }
        let policy = activeFrameFreshnessPolicy
        guard !inputIsActive(now: now, policy: policy),
              sourceIsStill(now: now, policy: policy),
              (packetSender?.queuedByteCount ?? 0) <= queuePressureBytes else {
            return []
        }
        let tiles = plan.tiles.sorted { lhs, rhs in
            if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
            return lhs.id < rhs.id
        }
        let index = mosaicQualityRefreshTileCursor % tiles.count
        mosaicQualityRefreshTileCursor = (index + 1) % tiles.count
        return [tiles[index].id]
    }
}
#endif
