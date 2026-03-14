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
    struct TransportSendErrorTracker: Sendable {
        var timestamps: [CFAbsoluteTime] = []
        var lastRecoveryTime: CFAbsoluteTime = 0
        var threshold: Int = 6
        var window: CFAbsoluteTime = 1.0
        var cooldown: CFAbsoluteTime = 2.0

        mutating func record(now: CFAbsoluteTime) -> Bool {
            timestamps.append(now)
            timestamps.removeAll { now - $0 > window }
            guard timestamps.count >= max(1, threshold) else { return false }
            if lastRecoveryTime > 0, now - lastRecoveryTime < cooldown {
                return false
            }
            lastRecoveryTime = now
            timestamps.removeAll(keepingCapacity: true)
            return true
        }
    }

    func handleTransportSendError(_ error: NWError) async -> Bool {
        var tracker = TransportSendErrorTracker(
            timestamps: transportSendErrorTimestamps,
            lastRecoveryTime: lastTransportSendErrorRecoveryTime,
            threshold: transportSendErrorThreshold,
            window: transportSendErrorWindow,
            cooldown: transportSendErrorRecoveryCooldown
        )
        let now = CFAbsoluteTimeGetCurrent()
        let shouldRecover = tracker.record(now: now)
        transportSendErrorTimestamps = tracker.timestamps
        lastTransportSendErrorRecoveryTime = tracker.lastRecoveryTime
        guard shouldRecover else { return false }

        transportSendErrorBursts &+= 1
        noteLossEvent(reason: "transport send error burst", enablePFrameFEC: true)
        await packetSender?.resetQueue(reason: "transport send error burst")
        clearBackpressureState(log: false)
        keyframeSendDeadline = 0
        lastKeyframeRequestTime = 0
        _ = queueKeyframe(
            reason: "Transport send error recovery keyframe",
            checkInFlight: false,
            urgent: true
        )
        MirageLogger.stream(
            "Transport send-error burst recovery for stream \(streamID): error=\(error), bursts=\(transportSendErrorBursts)"
        )
        return true
    }

    nonisolated func enqueueCapturedFrame(_ frame: CapturedFrame) {
        guard shouldEncodeFrames else { return }
        Task(priority: .userInitiated) { await self.recordCaptureIngress(frame) }
        if frame.info.isIdleFrame { return }
        if frameInbox.enqueue(frame) {
            Task(priority: .userInitiated) { await self.processPendingFrames() }
        }
    }

    func recordCaptureIngress(_ frame: CapturedFrame) {
        captureIngressIntervalCount += 1
        lastCapturedFrameTime = CFAbsoluteTimeGetCurrent()
        lastCapturedFrame = frame
        lastCapturedDuration = frame.duration
        if frame.info.isIdleFrame { idleSkippedCount += 1 }
        if startupBaseTime > 0, !startupFirstCaptureLogged {
            startupFirstCaptureLogged = true
            logStartupEvent("first captured frame")
        }
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
        if performanceMode == .game {
            MirageLogger.stream("Encoder in-flight stalled for \(Int(elapsedMs))ms (\(label)), forcing keyframe (game mode)")
            inFlightCount = 0
            lastEncodeActivityTime = 0
            isKeyframeEncoding = false
            keyframeSendDeadline = 0
            lastKeyframeRequestTime = 0
            _ = queueKeyframe(
                reason: "Encoder stall recovery (game mode)",
                checkInFlight: false,
                urgent: true
            )
            return true
        }
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
        lastCaptureStarvationRestartTime = 0
        backpressureActive = false
        backpressureActiveSnapshot = false
        backpressureActivatedAt = 0
        lastBackpressureRecoveryTime = 0
        lastCapturedFrame = nil
        lastCapturedFrameTime = 0
        lastCapturedDuration = .invalid
        lastEncodedPresentationTime = .invalid
        lastSyntheticFrameTime = 0
        lastSyntheticLogTime = 0
        typingBurstExpiryTask?.cancel()
        typingBurstExpiryTask = nil
        typingBurstActive = false
        typingBurstDeadline = 0
        if latencyBurstCaptureQueueDepthOverride != nil {
            encoderConfig.captureQueueDepth = preLatencyBurstCaptureQueueDepthOverride
        }
        latencyBurstActive = false
        latencyBurstDrainsNewestFrames = false
        latencyBurstCaptureQueueDepthOverride = nil
        preLatencyBurstCaptureQueueDepthOverride = nil
        if let encoder { scheduleEncoderTypingBurstUpdate(encoder, enabled: false) }
        maxInFlightFrames = resolvedPostTypingBurstInFlightLimit()
        qualityCeiling = resolvedQualityCeiling()
        if activeQuality > qualityCeiling { activeQuality = qualityCeiling }
        frameInbox.clear()
        temporaryDegradationStableWindows = 0
        temporaryDegradationOverloadWindows = 0
        temporaryDegradationSevereOverloadWindows = 0
    }

    func clearBackpressureState(queueBytes: Int? = nil, log: Bool = true) {
        let hadBackpressure = backpressureActive || backpressureActiveSnapshot || backpressureActivatedAt > 0
        backpressureActive = false
        backpressureActiveSnapshot = false
        backpressureActivatedAt = 0
        guard hadBackpressure, log, let queueBytes else { return }
        let queuedKB = Int((Double(queueBytes) / 1024.0).rounded())
        MirageLogger.stream("Backpressure cleared (queue \(queuedKB)KB)")
    }

    func triggerBackpressureRecoveryIfNeeded(queueBytes: Int, now: CFAbsoluteTime) async -> Bool {
        // Sunshine-style game-mode behavior prefers a steady encode/send pipeline over
        // queue-reset discontinuities. Keep recovery soft in game mode.
        guard performanceMode != .game else { return false }
        guard backpressureActive else { return false }
        let activationTime = backpressureActivatedAt > 0 ? backpressureActivatedAt : now
        if backpressureActivatedAt == 0 { backpressureActivatedAt = now }
        guard now - activationTime >= backpressureRecoveryThreshold else { return false }
        if lastBackpressureRecoveryTime > 0, now - lastBackpressureRecoveryTime < backpressureRecoveryCooldown {
            return false
        }

        lastBackpressureRecoveryTime = now
        backpressureActivatedAt = now

        let queuedKB = Int((Double(queueBytes) / 1024.0).rounded())
        MirageLogger.stream("Backpressure recovery: queue reset at \(queuedKB)KB")
        noteLossEvent(reason: "backpressure recovery", enablePFrameFEC: true)

        await packetSender?.resetQueue(reason: "backpressure recovery")
        clearBackpressureState(log: false)
        keyframeSendDeadline = 0
        lastKeyframeRequestTime = 0
        _ = queueKeyframe(
            reason: "Backpressure recovery keyframe",
            checkInFlight: false,
            urgent: true
        )
        return true
    }

    /// Process pending frames (encodes using HEVC and can switch to freshest-frame delivery).
    func processPendingFrames() async {
        defer {
            frameInbox.markDrainComplete()
            schedulePipelineStatsLog()
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

        // Capture admission drops can keep this loop alive without enqueued frames.
        // Re-check sender queue state so backpressure can clear even when we are not
        // currently processing a frame.
        if backpressureActive {
            let queueBytes = packetSender?.queuedBytesSnapshot() ?? 0
            if queueBytes <= queuePressureBytes { clearBackpressureState(queueBytes: queueBytes) }
        }

        while inFlightCount < maxInFlightFrames {
            let drainPolicy: StreamFrameInbox.DrainPolicy = if latencyBurstDrainsNewestFrames {
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
                if performanceMode == .game {
                    MirageLogger.stream("Encoder stuck for \(Int(stuckTime))ms, forcing keyframe (game mode)")
                    inFlightCount = 0
                    lastEncodeActivityTime = 0
                    keyframeSendDeadline = 0
                    lastKeyframeRequestTime = 0
                    _ = queueKeyframe(
                        reason: "Encoder stuck recovery (game mode)",
                        checkInFlight: false,
                        urgent: true
                    )
                } else {
                    MirageLogger.stream("Encoder stuck for \(Int(stuckTime))ms, scheduling reset")
                    inFlightCount = 0
                    lastEncodeActivityTime = 0
                    needsEncoderReset = true
                }
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
                        if performanceMode == .game {
                            MirageLogger.stream("Resetting stuck encoder with flush-only recovery (game mode)")
                            await encoder?.flush()
                        } else {
                            MirageLogger.stream("Resetting stuck encoder before next frame")
                            advanceEpoch(reason: "encoder reset")
                            await packetSender?.resetQueue(reason: "encoder reset")
                            try await encoder?.reset()
                        }
                        didResetEncoder = true
                        lastEncoderResetTime = now
                    } catch {
                        MirageLogger.error(.stream, error: error, message: "Encoder reset failed: ")
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
            let backpressureTriggerBytes = performanceMode == .game
                ? max(maxQueuedBytes, Self.gameModeBackpressureTriggerBytes)
                : maxQueuedBytes
            if performanceMode == .game, backpressureActive {
                clearBackpressureState(log: false)
            }

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

            if performanceMode == .game {
                if queueBytes > backpressureTriggerBytes, !forceKeyframe {
                    // Sunshine-style behavior: do not enter sticky backpressure/reset loops.
                    // Drop only the current frame when transport backlog spikes.
                    backpressureActiveSnapshot = false
                    backpressureActivatedAt = 0
                    backpressureActive = false
                    backpressureDropIntervalCount += 1
                    droppedFrameCount += 1
                    await logStreamStatsIfNeeded()
                    continue
                }
            } else if backpressureActive {
                if queueBytes <= queuePressureBytes {
                    clearBackpressureState(queueBytes: queueBytes)
                } else if await triggerBackpressureRecoveryIfNeeded(
                    queueBytes: queueBytes,
                    now: CFAbsoluteTimeGetCurrent()
                ) {
                    await logStreamStatsIfNeeded()
                    continue
                } else {
                    backpressureDropIntervalCount += 1
                    droppedFrameCount += 1
                    await logStreamStatsIfNeeded()
                    continue
                }
            } else if queueBytes > backpressureTriggerBytes, !forceKeyframe {
                backpressureActive = true
                backpressureActiveSnapshot = true
                if backpressureActivatedAt == 0 { backpressureActivatedAt = CFAbsoluteTimeGetCurrent() }
                backpressureDropIntervalCount += 1
                droppedFrameCount += 1
                let queuedKB = (Double(queueBytes) / 1024.0).rounded()
                MirageLogger.stream("Backpressure: pausing encode (queue \(Int(queuedKB))KB)")
                await logStreamStatsIfNeeded()
                continue
            }

            if shouldQueueScheduledKeyframe(queueBytes: queueBytes) { queueKeyframe(reason: "Scheduled keyframe", checkInFlight: true) }

            let isIdleFrame = frame.info.isIdleFrame
            if isIdleFrame {
                if captureMode == .window {
                    idleSkippedCount += 1
                    await logStreamStatsIfNeeded()
                    continue
                }
                // Display capture can report sustained idle status during fullscreen/menu transitions.
                // Keep encoding these frames so the client does not enter visible motion freezes.
                syntheticFrameCount += 1
                syntheticIntervalCount += 1
            }

            setContentRect(frame.info.contentRect)
            enforceCaptureColorAttachments(on: frame.pixelBuffer)
            applyTrafficLightCloneStampIfNeeded(frame: frame)

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

        if frameInbox.hasPending(), inFlightCount < maxInFlightFrames { scheduleProcessingIfNeeded() }
    }

    func applyTrafficLightCloneStampIfNeeded(frame: CapturedFrame) {
        guard isAppStream, windowID != 0 else { return }

        let windowFramePoints = resolvedWindowFramePointsForTrafficLightMask(frame: frame)
        guard windowFramePoints.width > 0, windowFramePoints.height > 0 else { return }
        let contentRect = resolvedContentRectForTrafficLightMask(frame: frame)
        guard contentRect.width > 0, contentRect.height > 0 else { return }

        let geometry = resolveTrafficLightMaskGeometry(windowFramePoints: windowFramePoints)
        let result = trafficLightCloneStampCompositor.apply(
            to: frame.pixelBuffer,
            contentRect: contentRect,
            geometry: geometry
        )
        logTrafficLightCloneStampResultIfNeeded(result, geometry: geometry)
    }

    func resolvedWindowFramePointsForTrafficLightMask(frame: CapturedFrame) -> CGRect {
        if !lastWindowFrame.isEmpty, lastWindowFrame.width > 0, lastWindowFrame.height > 0 {
            return lastWindowFrame
        }

        let contentRect = frame.info.contentRect
        guard contentRect.width > 0, contentRect.height > 0 else {
            return .zero
        }

        return CGRect(
            x: 0,
            y: 0,
            width: contentRect.width,
            height: contentRect.height
        )
    }

    func resolvedContentRectForTrafficLightMask(frame: CapturedFrame) -> CGRect {
        if useVirtualDisplay {
            return CGRect(
                x: 0,
                y: 0,
                width: CVPixelBufferGetWidth(frame.pixelBuffer),
                height: CVPixelBufferGetHeight(frame.pixelBuffer)
            )
        }

        let contentRect = frame.info.contentRect
        if contentRect.width > 0, contentRect.height > 0 {
            return contentRect
        }

        return CGRect(
            x: 0,
            y: 0,
            width: CVPixelBufferGetWidth(frame.pixelBuffer),
            height: CVPixelBufferGetHeight(frame.pixelBuffer)
        )
    }

    func resolveTrafficLightMaskGeometry(windowFramePoints: CGRect) -> HostTrafficLightMaskGeometryResolver.ResolvedGeometry {
        let now = CFAbsoluteTimeGetCurrent()
        if let cache = trafficLightMaskGeometryCache,
           HostTrafficLightMaskGeometryResolver.shouldUseCached(
               cache,
               now: now,
               windowFramePoints: windowFramePoints,
               ttl: trafficLightMaskGeometryCacheTTL,
               frameTolerance: trafficLightMaskGeometryFrameTolerance
           ) {
            return cache.geometry
        }

        let geometry = HostTrafficLightMaskGeometryResolver.resolve(
            windowID: windowID,
            windowFramePoints: windowFramePoints,
            appProcessID: applicationProcessID > 0 ? applicationProcessID : nil
        )
        trafficLightMaskGeometryCache = HostTrafficLightMaskGeometryResolver.CacheEntry(
            geometry: geometry,
            sampledAt: now,
            sampledWindowFrame: windowFramePoints
        )
        return geometry
    }

    func logTrafficLightCloneStampResultIfNeeded(
        _ result: HostTrafficLightCloneStampCompositor.ApplyResult,
        geometry: HostTrafficLightMaskGeometryResolver.ResolvedGeometry
    ) {
        guard case let .skipped(reason) = result else { return }
        guard reason != .hiddenTrafficLights else { return }

        let now = CFAbsoluteTimeGetCurrent()
        if now - lastTrafficLightMaskLogTime < trafficLightMaskLogInterval {
            return
        }
        lastTrafficLightMaskLogTime = now
        MirageLogger.debug(
            .stream,
            "Traffic-light clone-stamp skipped for stream \(streamID) window \(windowID): reason=\(reason.rawValue), source=\(geometry.source.rawValue)"
        )
    }

    func logStreamStatsIfNeeded() async {
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
            let averageEncodeMs = await encoder?.getAverageEncodeTimeMs()
            let resolvedAverageEncodeMs: Double? = if let averageEncodeMs, averageEncodeMs > 0 {
                averageEncodeMs
            } else {
                nil
            }
            let captureValidation = captureValidationSnapshot()
            let encoderValidation = await encoder?.runtimeValidationSnapshot()
            let displayP3CoverageStatus = resolvedDisplayP3CoverageStatus(
                capture: captureValidation,
                encoder: encoderValidation
            )
            await applyUltraValidationDowngradeIfNeeded(encoderValidation)
            let currentBitrate = temporaryDegradationCurrentBitrate ?? encoderConfig.bitrate
            let timeBelowTargetBitrateMs: Int? = if temporaryDegradationBelowTargetSince > 0 {
                Int(((now - temporaryDegradationBelowTargetSince) * 1000).rounded())
            } else {
                nil
            }
            let frameBudgetMs = 1000.0 / Double(max(1, currentFrameRate))
            let encodedWidth = Int(currentEncodedSize.width)
            let encodedHeight = Int(currentEncodedSize.height)
            let message = StreamMetricsMessage(
                streamID: streamID,
                encodedFPS: encodedFPS,
                idleEncodedFPS: idleEncodedFPS,
                droppedFrames: droppedFrameCount,
                activeQuality: activeQuality,
                targetFrameRate: currentFrameRate,
                currentBitrate: currentBitrate,
                requestedTargetBitrate: requestedTargetBitrate,
                startupBitrate: startupBitrate,
                temporaryDegradationMode: temporaryDegradationMode,
                temporaryDegradationColorDepth: temporaryDegradationCurrentColorDepth,
                timeBelowTargetBitrateMs: timeBelowTargetBitrateMs,
                captureAdmissionDrops: captureDroppedIntervalCount,
                frameBudgetMs: frameBudgetMs,
                averageEncodeMs: resolvedAverageEncodeMs,
                usingHardwareEncoder: encoderValidation?.usingHardwareEncoder,
                encoderGPURegistryID: encoderValidation?.encoderGPURegistryID,
                encodedWidth: encodedWidth > 0 ? encodedWidth : nil,
                encodedHeight: encodedHeight > 0 ? encodedHeight : nil,
                capturePixelFormat: captureValidation?.pixelFormat,
                captureColorPrimaries: captureValidation?.colorPrimaries,
                encoderPixelFormat: encoderValidation?.pixelFormat.displayName,
                encoderChromaSampling: encoderValidation?.encodedChromaSampling?.rawValue,
                encoderProfile: encoderValidation?.profileName,
                encoderColorPrimaries: encoderValidation?.colorPrimaries,
                encoderTransferFunction: encoderValidation?.transferFunction,
                encoderYCbCrMatrix: encoderValidation?.yCbCrMatrix,
                displayP3CoverageStatus: displayP3CoverageStatus,
                tenBitDisplayP3Validated: tenBitDisplayP3Validation(
                    capture: captureValidation,
                    encoder: encoderValidation,
                    coverageStatus: displayP3CoverageStatus
                ),
                ultra444Validated: encoderValidation?.ultra444Validated
            )
            metricsUpdateHandler(message)
        }
        encodedFrameCount = 0
        idleEncodedCount = 0
        syntheticFrameCount = 0
        idleSkippedCount = 0
        lastStreamStatsLogTime = now
    }

    private struct CaptureValidationSnapshot: Sendable {
        let pixelFormat: String
        let colorPrimaries: String?
        let transferFunction: String?
        let yCbCrMatrix: String?
        let isTenBitP010: Bool
        let isDisplayP3: Bool?
    }

    private func captureValidationSnapshot() -> CaptureValidationSnapshot? {
        guard let pixelBuffer = lastCapturedFrame?.pixelBuffer else { return nil }
        let pixelFormatType = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let pixelFormat = HEVCEncoder.fourCCString(pixelFormatType)
        let isTenBitP010 = pixelFormatType == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange ||
            pixelFormatType == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        let colorPrimaries = bufferAttachmentString(pixelBuffer, key: kCVImageBufferColorPrimariesKey)
        let transferFunction = bufferAttachmentString(pixelBuffer, key: kCVImageBufferTransferFunctionKey)
        let yCbCrMatrix = bufferAttachmentString(pixelBuffer, key: kCVImageBufferYCbCrMatrixKey)
        let isDisplayP3: Bool? = {
            guard let colorPrimaries,
                  let transferFunction,
                  let yCbCrMatrix else { return nil }
            return colorPrimaries == (kCVImageBufferColorPrimaries_P3_D65 as String) &&
                transferFunction == (kCVImageBufferTransferFunction_sRGB as String) &&
                yCbCrMatrix == (kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String)
        }()
        return CaptureValidationSnapshot(
            pixelFormat: pixelFormat,
            colorPrimaries: colorPrimaries,
            transferFunction: transferFunction,
            yCbCrMatrix: yCbCrMatrix,
            isTenBitP010: isTenBitP010,
            isDisplayP3: isDisplayP3
        )
    }

    private func applyUltraValidationDowngradeIfNeeded(
        _ encoderValidation: HEVCEncoder.RuntimeValidationSnapshot?
    )
    async {
        guard encoderConfig.colorDepth == .ultra else {
            ultraValidationFailureHandled = false
            ultraValidationSuccessLogged = false
            return
        }
        guard let encoderValidation else { return }

        if encoderValidation.ultra444Validated {
            if !ultraValidationSuccessLogged {
                let chromaText = encoderValidation.encodedChromaSampling?.rawValue ?? "unknown"
                MirageLogger.stream(
                    "Ultra color depth validation passed for stream \(streamID): " +
                        "pixelFormat=\(encoderValidation.pixelFormat.displayName), chroma=\(chromaText), " +
                        "profile=\(encoderValidation.profileName ?? "automatic")"
                )
                ultraValidationSuccessLogged = true
            }
            ultraValidationFailureHandled = false
            return
        }

        guard encoderValidation.encodedChromaSampling != nil else { return }
        guard !ultraValidationFailureHandled else { return }
        ultraValidationFailureHandled = true

        let chromaText = encoderValidation.encodedChromaSampling?.rawValue ?? "unknown"
        MirageLogger.error(
            .stream,
            "Ultra color depth validation failed for stream \(streamID): " +
                "pixelFormat=\(encoderValidation.pixelFormat.displayName), chroma=\(chromaText), " +
                "profile=\(encoderValidation.profileName ?? "automatic"); downgrading to Pro"
        )

        do {
            try await updateEncoderSettings(
                colorDepth: .pro,
                bitrate: encoderConfig.bitrate
            )
        } catch {
            MirageLogger.error(
                .stream,
                error: error,
                message: "Ultra color depth downgrade failed: "
            )
        }
    }

    private func tenBitDisplayP3Validation(
        capture: CaptureValidationSnapshot?,
        encoder: HEVCEncoder.RuntimeValidationSnapshot?,
        coverageStatus: MirageDisplayP3CoverageStatus?
    ) -> Bool? {
        Self.measuredTenBitDisplayP3Validation(
            coverageStatus: coverageStatus,
            captureIsTenBitP010: capture?.isTenBitP010,
            captureIsDisplayP3: capture?.isDisplayP3,
            encoderTenBitDisplayP3Validated: encoder?.tenBitDisplayP3Validated
        )
    }

    static func measuredTenBitDisplayP3Validation(
        coverageStatus: MirageDisplayP3CoverageStatus?,
        captureIsTenBitP010: Bool?,
        captureIsDisplayP3: Bool?,
        encoderTenBitDisplayP3Validated: Bool?
    ) -> Bool? {
        guard let coverageStatus else { return nil }
        let measuredCoveragePass = coverageStatus == .strictCanonical || coverageStatus == .wideGamutEquivalent
        guard measuredCoveragePass else { return false }
        guard let captureIsTenBitP010,
              let captureIsDisplayP3,
              let encoderTenBitDisplayP3Validated else { return nil }
        return captureIsTenBitP010 && captureIsDisplayP3 && encoderTenBitDisplayP3Validated
    }

    private func resolvedDisplayP3CoverageStatus(
        capture: CaptureValidationSnapshot?,
        encoder: HEVCEncoder.RuntimeValidationSnapshot?
    ) -> MirageDisplayP3CoverageStatus? {
        if let override = displayP3CoverageStatusOverride {
            return override
        }
        if let virtualDisplayContext {
            return virtualDisplayContext.displayP3CoverageStatus
        }
        if encoderConfig.colorSpace == .sRGB {
            return .sRGBFallback
        }
        guard encoderConfig.colorSpace == .displayP3 else { return nil }
        guard let capture else { return .unresolved }
        guard let captureIsDisplayP3 = capture.isDisplayP3 else { return .unresolved }
        if captureIsDisplayP3, encoder?.tenBitDisplayP3Validated == true {
            return .strictCanonical
        }
        if captureIsDisplayP3 {
            return .wideGamutEquivalent
        }
        return .sRGBFallback
    }

    private func bufferAttachmentString(_ buffer: CVBuffer, key: CFString) -> String? {
        CVBufferCopyAttachment(buffer, key, nil) as? String
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
            pendingCount: pendingCount,
            at: now
        )
        await evaluateGameModeDeficitWindowIfNeeded(
            encodedFPS: encodeFPS,
            averageEncodeMs: encodeAvgMs,
            at: now
        )
        await evaluateStandardTemporaryDegradationIfNeeded(
            encodedFPS: encodeFPS,
            averageEncodeMs: encodeAvgMs,
            queueBytes: queueBytes,
            captureDroppedFrames: captureDroppedIntervalCount,
            at: now
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

    func updateInFlightLimitIfNeeded(
        averageEncodeMs: Double,
        pendingCount: Int,
        at now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    )
    async {
        await refreshTypingBurstStateIfNeeded(now: now)

        if supportsTypingBurst, typingBurstActive {
            let forcedLimit = min(max(typingBurstInFlightLimit, 1), maxInFlightFramesCap)
            if maxInFlightFrames != forcedLimit {
                maxInFlightFrames = forcedLimit
                await encoder?.updateInFlightLimit(forcedLimit)
            }
            return
        }

        guard maxInFlightFramesCap > 1 else { return }
        if useLowLatencyPipeline {
            let baselineLowLatencyLimit: Int
            if performanceMode == .game {
                baselineLowLatencyLimit = currentFrameRate >= 120
                    ? 2
                    : StreamContext.gameModeLowLatencyInFlightLimit
            } else {
                baselineLowLatencyLimit = currentFrameRate >= 120 ? 2 : 1
            }
            let lowLatencyLimit = min(maxInFlightFramesCap, max(1, baselineLowLatencyLimit))
            if maxInFlightFrames != lowLatencyLimit {
                maxInFlightFrames = lowLatencyLimit
                await encoder?.updateInFlightLimit(lowLatencyLimit)
                MirageLogger.metrics(
                    "In-flight depth forced to \(lowLatencyLimit) (low latency pipeline, mode=\(performanceMode.rawValue))"
                )
            }
            return
        }

        if lastInFlightAdjustmentTime > 0, now - lastInFlightAdjustmentTime < inFlightAdjustmentCooldown { return }

        let frameBudgetMs = 1000.0 / Double(max(1, currentFrameRate))
        var desired = maxInFlightFrames

        let smoothnessFirstMode = latencyMode == .smoothest || latencyMode == .auto
        let increaseThreshold = smoothnessFirstMode ? 1.02 : 1.10
        let decreaseThreshold = smoothnessFirstMode ? 0.90 : 0.80
        if averageEncodeMs > frameBudgetMs * increaseThreshold || pendingCount > 0 {
            desired = min(maxInFlightFrames + 1, maxInFlightFramesCap)
        } else if averageEncodeMs < frameBudgetMs * decreaseThreshold, pendingCount == 0 {
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

    func evaluateGameModeDeficitWindowIfNeeded(
        encodedFPS: Double,
        averageEncodeMs: Double,
        at now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    )
    async {
        guard performanceMode == .game else { return }
        // Sunshine-compatible game mode keeps a static encoder policy in-session.
        _ = encodedFPS
        _ = averageEncodeMs
        _ = now
    }

    private func advanceGameModeStage(encodedFPS: Double, averageEncodeMs: Double) async {
        if gameModeStage == .stage3Emergency { return }
        let priorStage = gameModeStage
        let nextStage: GameModeStage = switch gameModeStage {
        case .baseline:
            .stage1FrameRate60
        case .stage1FrameRate60:
            .stage2EightBit
        case .stage2EightBit:
            .stage3Emergency
        case .stage3Emergency:
            .stage3Emergency
        }
        guard nextStage != priorStage else { return }
        gameModeStage = nextStage
        gameModeConsecutiveHealthyWindows = 0

        let applied: Bool = switch nextStage {
        case .stage1FrameRate60:
            await applyGameModeStage1FrameRateOverride()
        case .stage2EightBit:
            await applyGameModeStage2BitDepthOverride()
        case .stage3Emergency:
            await applyGameModeStage3EmergencyOverride()
        case .baseline:
            false
        }

        let encodedText = encodedFPS.formatted(.number.precision(.fractionLength(2)))
        let avgText = averageEncodeMs.formatted(.number.precision(.fractionLength(2)))
        MirageLogger
            .metrics(
                "event=game_mode_stage_transition stream=\(streamID) from=\(priorStage.logName) to=\(nextStage.logName) " +
                    "applied=\(applied) encodedFPS=\(encodedText) avgEncodeMs=\(avgText)"
            )
    }

    private func restoreGameModeStage(encodedFPS: Double, averageEncodeMs: Double) async {
        guard gameModeStage != .baseline else { return }
        let priorStage = gameModeStage
        let nextStage: GameModeStage = switch gameModeStage {
        case .baseline:
            .baseline
        case .stage1FrameRate60:
            .baseline
        case .stage2EightBit:
            .stage1FrameRate60
        case .stage3Emergency:
            .stage2EightBit
        }
        guard nextStage != priorStage else { return }

        let applied: Bool = switch priorStage {
        case .stage3Emergency:
            await restoreGameModeStage3EmergencyOverride()
        case .stage2EightBit:
            await restoreGameModeStage2BitDepthOverride()
        case .stage1FrameRate60:
            await restoreGameModeStage1FrameRateOverride()
        case .baseline:
            false
        }
        gameModeStage = nextStage

        let encodedText = encodedFPS.formatted(.number.precision(.fractionLength(2)))
        let avgText = averageEncodeMs.formatted(.number.precision(.fractionLength(2)))
        MirageLogger
            .metrics(
                "event=game_mode_stage_restore stream=\(streamID) from=\(priorStage.logName) to=\(nextStage.logName) " +
                    "applied=\(applied) encodedFPS=\(encodedText) avgEncodeMs=\(avgText)"
            )
    }

    private func shouldUseStandardTemporaryDegradationGovernor() -> Bool {
        performanceMode == .standard &&
            streamKind == .desktop &&
            temporaryDegradationMode != .off &&
            (requestedTargetBitrate ?? 0) > 0
    }

    func evaluateStandardTemporaryDegradationIfNeeded(
        encodedFPS: Double,
        averageEncodeMs: Double,
        queueBytes: Int,
        captureDroppedFrames: UInt64,
        at now: CFAbsoluteTime
    ) async {
        guard shouldUseStandardTemporaryDegradationGovernor(),
              let requestedTargetBitrate,
              requestedTargetBitrate > 0 else {
            temporaryDegradationStableWindows = 0
            temporaryDegradationOverloadWindows = 0
            temporaryDegradationSevereOverloadWindows = 0
            return
        }

        let currentBitrate = temporaryDegradationCurrentBitrate ?? encoderConfig.bitrate ?? requestedTargetBitrate
        updateTemporaryDegradationBelowTargetState(
            now: now,
            currentBitrate: currentBitrate,
            requestedBitrate: requestedTargetBitrate
        )

        let targetFPS = Double(max(1, currentFrameRate))
        let frameBudgetMs = 1000.0 / targetFPS
        let fpsRatio = encodedFPS / targetFPS
        let queuePressured = queueBytes > queuePressureBytes
        let queueSeverelyPressured = queueBytes > maxQueuedBytes
        let isStable = averageEncodeMs > 0 &&
            fpsRatio >= temporaryDegradationStableThresholdRatio &&
            averageEncodeMs <= frameBudgetMs * temporaryDegradationStableEncodeBudgetRatio &&
            captureDroppedFrames == 0 &&
            !queuePressured
        let isOverloaded = fpsRatio < temporaryDegradationStableThresholdRatio ||
            averageEncodeMs > frameBudgetMs * temporaryDegradationOverBudgetRatio ||
            captureDroppedFrames > 0 ||
            queuePressured
        let isSeverelyOverloaded = fpsRatio < temporaryDegradationSevereThresholdRatio ||
            averageEncodeMs > frameBudgetMs * temporaryDegradationSevereEncodeBudgetRatio ||
            captureDroppedFrames >= 12 ||
            queueSeverelyPressured

        if isStable {
            temporaryDegradationOverloadWindows = 0
            temporaryDegradationSevereOverloadWindows = 0
            temporaryDegradationStableWindows += 1
            guard temporaryDegradationStableWindows >= temporaryDegradationStableWindowsThreshold else { return }
            if await attemptTemporaryDegradationRestore(
                currentBitrate: currentBitrate,
                requestedBitrate: requestedTargetBitrate,
                at: now
            ) {
                temporaryDegradationStableWindows = 0
            }
            return
        }

        temporaryDegradationStableWindows = 0
        guard isOverloaded else {
            temporaryDegradationOverloadWindows = 0
            temporaryDegradationSevereOverloadWindows = 0
            return
        }

        temporaryDegradationOverloadWindows += 1
        if isSeverelyOverloaded {
            temporaryDegradationSevereOverloadWindows += 1
        } else {
            temporaryDegradationSevereOverloadWindows = 0
        }

        if await attemptTemporaryDegradationRelief(
            currentBitrate: currentBitrate,
            requestedBitrate: requestedTargetBitrate,
            severe: isSeverelyOverloaded,
            at: now
        ) {
            temporaryDegradationOverloadWindows = 0
            let shouldPreserveSevereWindowStreak = temporaryDegradationMode == .prioritizeVisuals &&
                temporaryDegradationCurrentColorDepth != .standard &&
                isSeverelyOverloaded
            if !shouldPreserveSevereWindowStreak {
                temporaryDegradationSevereOverloadWindows = 0
            }
        }
    }

    private func attemptTemporaryDegradationRestore(
        currentBitrate: Int,
        requestedBitrate: Int,
        at now: CFAbsoluteTime
    ) async -> Bool {
        if currentBitrate < requestedBitrate {
            let ramped = Int((Double(currentBitrate) * temporaryDegradationRampStep).rounded(.up))
            let nextBitrate = min(requestedBitrate, max(currentBitrate + 1, ramped))
            if nextBitrate > currentBitrate {
                return await applyTemporaryDegradationAdjustment(
                    colorDepth: nil,
                    bitrate: nextBitrate,
                    reason: "temporary degradation bitrate ramp",
                    now: now
                )
            }
        }

        updateTemporaryDegradationBelowTargetState(
            now: now,
            currentBitrate: currentBitrate,
            requestedBitrate: requestedBitrate
        )
        return false
    }

    private func attemptTemporaryDegradationRelief(
        currentBitrate: Int,
        requestedBitrate: Int,
        severe _: Bool,
        at now: CFAbsoluteTime
    ) async -> Bool {
        let floor = min(requestedBitrate, temporaryDegradationBitrateFloorBps)

        switch temporaryDegradationMode {
        case .off:
            return false

        case .prioritizeFramerate:
            let nextBitrate = max(
                floor,
                Int((Double(currentBitrate) * temporaryDegradationBitrateStepFramerate).rounded(.down))
            )
            guard nextBitrate < currentBitrate else { return false }
            return await applyTemporaryDegradationAdjustment(
                colorDepth: nil,
                bitrate: nextBitrate,
                reason: "temporary degradation framerate-first bitrate drop",
                now: now
                )

        case .prioritizeVisuals:
            let nextBitrate = max(
                floor,
                Int((Double(currentBitrate) * temporaryDegradationBitrateStepVisuals).rounded(.down))
            )
            if nextBitrate < currentBitrate {
                return await applyTemporaryDegradationAdjustment(
                    colorDepth: nil,
                    bitrate: nextBitrate,
                    reason: "temporary degradation visuals-first bitrate drop",
                    now: now
                )
            }

            return false
        }
    }

    private func applyTemporaryDegradationAdjustment(
        colorDepth: MirageStreamColorDepth?,
        bitrate: Int?,
        reason: String,
        now: CFAbsoluteTime
    ) async -> Bool {
        let desiredColorDepth = colorDepth ?? temporaryDegradationCurrentColorDepth
        let desiredBitrate = bitrate ?? temporaryDegradationCurrentBitrate
        guard desiredColorDepth != temporaryDegradationCurrentColorDepth ||
            desiredBitrate != temporaryDegradationCurrentBitrate else {
            return false
        }

        do {
            if isRunning {
                try await updateEncoderSettings(
                    colorDepth: desiredColorDepth == temporaryDegradationCurrentColorDepth ? nil : desiredColorDepth,
                    bitrate: desiredBitrate
                )
            } else {
                encoderConfig = encoderConfig.withOverrides(
                    colorDepth: desiredColorDepth == temporaryDegradationCurrentColorDepth ? nil : desiredColorDepth,
                    bitrate: desiredBitrate
                )
                activePixelFormat = encoderConfig.pixelFormat
                temporaryDegradationCurrentBitrate = encoderConfig.bitrate
                temporaryDegradationCurrentColorDepth = encoderConfig.colorDepth
                if currentEncodedSize != .zero {
                    await applyDerivedQuality(for: currentEncodedSize, logLabel: "Temporary degradation")
                }
            }
            temporaryDegradationCurrentColorDepth = encoderConfig.colorDepth
            temporaryDegradationCurrentBitrate = encoderConfig.bitrate
            updateTemporaryDegradationBelowTargetState(
                now: now,
                currentBitrate: temporaryDegradationCurrentBitrate ?? 0,
                requestedBitrate: requestedTargetBitrate ?? 0
            )
            let bitrateText = (temporaryDegradationCurrentBitrate ?? 0)
                .formatted(.number.grouping(.never))
            MirageLogger.metrics(
                "event=temporary_degradation_adjustment stream=\(streamID) mode=\(temporaryDegradationMode.rawValue) reason=\(reason) colorDepth=\(temporaryDegradationCurrentColorDepth.displayName) bitrate=\(bitrateText)"
            )
            return true
        } catch {
            MirageLogger.error(.stream, error: error, message: "Temporary degradation adjustment failed: ")
            return false
        }
    }

    private func updateTemporaryDegradationBelowTargetState(
        now: CFAbsoluteTime,
        currentBitrate: Int,
        requestedBitrate: Int
    ) {
        guard requestedBitrate > 0 else {
            temporaryDegradationBelowTargetSince = 0
            return
        }

        if currentBitrate < requestedBitrate {
            if temporaryDegradationBelowTargetSince == 0 {
                temporaryDegradationBelowTargetSince = now
            }
        } else {
            temporaryDegradationBelowTargetSince = 0
        }
    }

    func adjustQualityForQueue(queueBytes: Int) async {
        guard let encoder else { return }
        guard runtimeQualityAdjustmentEnabled else { return }
        await refreshTypingBurstStateIfNeeded()
        qualityCeiling = resolvedQualityCeiling()
        if activeQuality > qualityCeiling {
            activeQuality = qualityCeiling
            await encoder.updateQuality(activeQuality)
        }
        if supportsTypingBurst, typingBurstActive { return }
        let now = CFAbsoluteTimeGetCurrent()
        if lastQualityAdjustmentTime > 0, now - lastQualityAdjustmentTime < qualityAdjustmentCooldown { return }

        let averageEncodeMs = await encoder.getAverageEncodeTimeMs()
        if averageEncodeMs <= 0 { return }

        let frameBudgetMs = 1000.0 / Double(max(1, currentFrameRate))
        let encodeOverBudget = averageEncodeMs > frameBudgetMs * 1.05
        let queuePressured = queueBytes > queuePressureBytes
        let highPressure = queueBytes > maxQueuedBytes
        let packetBudget = await packetSender?.packetBudgetSnapshot(now: now)
        let packetUtilization = packetBudget?.utilization ?? 0
        let packetOverBudget = packetUtilization > packetBudgetDropUtilizationThreshold
        let packetHighPressure = packetUtilization > packetBudgetHighPressureUtilizationThreshold
        let packetWithinRaiseBudget = packetUtilization > 0
            ? packetUtilization < packetBudgetRaiseUtilizationThreshold
            : true
        let fixedGameModeQuality = performanceMode == .game && !gameModeAggressiveQualityDropEnabled
        let qualityDropSignal = queuePressured || packetOverBudget || (!fixedGameModeQuality && encodeOverBudget)
        let bitrateConstrained = (encoderConfig.bitrate ?? 0) > 0
        let baseDropThreshold = gameModeAggressiveQualityDropEnabled
            ? gameModeAggressiveQualityDropThreshold
            : qualityDropThreshold
        let baseDropStep = gameModeAggressiveQualityDropEnabled
            ? gameModeAggressiveQualityDropStep
            : qualityDropStep
        let baseHighPressureDropStep = gameModeAggressiveQualityDropEnabled
            ? gameModeAggressiveQualityDropStepHighPressure
            : qualityDropStepHighPressure

        if qualityDropSignal {
            qualityUnderBudgetCount = 0
            qualityOverBudgetCount += 1
            let dropThreshold: Int = if bitrateConstrained && (highPressure || packetHighPressure) {
                1
            } else if bitrateConstrained && (queuePressured || packetOverBudget) {
                max(1, baseDropThreshold - 1)
            } else {
                baseDropThreshold
            }
            let step: Float = if highPressure || packetHighPressure {
                bitrateConstrained
                    ? (baseHighPressureDropStep + 0.03)
                    : baseHighPressureDropStep
            } else if bitrateConstrained && (queuePressured || packetOverBudget) {
                baseDropStep + 0.01
            } else {
                baseDropStep
            }
            if qualityOverBudgetCount >= dropThreshold {
                let next = max(qualityFloor, activeQuality - step)
                if next < activeQuality {
                    activeQuality = next
                    await encoder.updateQuality(activeQuality)
                    lastQualityAdjustmentTime = now
                    qualityOverBudgetCount = 0
                    let qualityText = activeQuality.formatted(.number.precision(.fractionLength(2)))
                    let avgText = averageEncodeMs.formatted(.number.precision(.fractionLength(1)))
                    let packetUtilizationText: String = if let packetBudget {
                        packetBudget.utilization.formatted(.number.precision(.fractionLength(2)))
                    } else {
                        "n/a"
                    }
                    MirageLogger.metrics(
                        "Quality down to \(qualityText) (encode \(avgText)ms, queue \(queueBytes / 1024)KB, packetUtil \(packetUtilizationText)x)"
                    )
                }
            }
        } else {
            qualityOverBudgetCount = 0
            if !packetWithinRaiseBudget {
                qualityUnderBudgetCount = 0
                return
            }
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
                    let packetUtilizationText: String = if let packetBudget {
                        packetBudget.utilization.formatted(.number.precision(.fractionLength(2)))
                    } else {
                        "n/a"
                    }
                    MirageLogger.metrics(
                        "Quality up to \(qualityText) (encode \(avgText)ms, packetUtil \(packetUtilizationText)x)"
                    )
                }
            }
        }
    }
}
#endif
