//
//  StreamContext+Metrics.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/9/26.
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

#if os(macOS)

extension StreamContext {
    /// Schedules a deferred pipeline-stat sample without stacking duplicate tasks.
    func schedulePipelineStatsLog() {
        guard !pipelineStatsLogScheduled else { return }
        pipelineStatsLogScheduled = true
        Task(priority: .utility) { [weak self] in
            await self?.runScheduledPipelineStatsLog()
        }
    }

    private func runScheduledPipelineStatsLog() async {
        await logPipelineStatsIfNeeded()
        pipelineStatsLogScheduled = false
    }

    func logStreamStatsIfNeeded() async {
        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = now - lastStreamStatsLogTime
        guard lastStreamStatsLogTime == 0 || elapsed > 2.0 else { return }
        let inFlight = inFlightCount
        if MirageSteadyStateDiagnostics.isEnabled, MirageLogger.isEnabled(.metrics) {
            MirageLogger.metrics(
                "Encode stats: encoded=\(encodedFrameCount), idleEncoded=\(idleEncodedCount), synthetic=\(syntheticFrameCount), idleSkipped=\(idleSkippedCount), inFlight=\(inFlight)"
            )
        }
        if let metricsUpdateHandler, lastStreamStatsLogTime > 0 {
            let encodedFPS = Double(encodedFrameCount) / elapsed
            let idleEncodedFPS = Double(idleEncodedCount) / elapsed
            let averageEncodeMs = await encoder?.averageEncodeTimeMs
            let encodedOutput = await encoder?.encodedOutputSnapshot()
            let resolvedAverageEncodeMs: Double? = if let averageEncodeMs, averageEncodeMs > 0 {
                averageEncodeMs
            } else {
                nil
            }
            let captureValidation = captureValidationSnapshot()
            let encoderValidation = await encoder?.runtimeValidationSnapshot
            let captureTelemetry = await consumeActiveCaptureTelemetrySnapshot()
            let capturePolicy = await activeCapturePolicySnapshot()
            let packetTelemetry = await packetSender?.consumeTelemetrySnapshot(
                queuedUnreliableProfile: mediaSendProfile
            )
            await applyQueuedUnreliableBurstPressureIfNeeded(packetTelemetry, now: now)
            let displayP3CoverageStatus = resolvedDisplayP3CoverageStatus(
                capture: captureValidation,
                encoder: encoderValidation
            )
            await applyUltraValidationDowngradeIfNeeded(encoderValidation)
            let currentBitrate = currentTargetBitrateBps ?? encoderConfig.bitrate
            let frameBudgetMs = 1000.0 / Double(max(1, currentFrameRate))
            let encodedWidth = Int(currentEncodedSize.width)
            let encodedHeight = Int(currentEncodedSize.height)
            let captureCadenceMetrics = streamCaptureCadenceMetrics(
                telemetry: captureTelemetry,
                policy: capturePolicy
            )
            let awdlPolicy = transportController.latestAwdlMediaDecision
            let message = MirageWire.StreamMetricsMessage(
                streamID: streamID,
                encodedFPS: encodedFPS,
                idleEncodedFPS: idleEncodedFPS,
                droppedFrames: droppedFrameCount,
                activeQuality: activeQuality,
                targetFrameRate: currentFrameRate,
                enteredBitrate: enteredTargetBitrate,
                currentBitrate: currentBitrate,
                encoderRequestedBitrateBps: encodedOutput?.requestedBitrateBps,
                encoderActualBitrateBps: encodedOutput?.actualBitrateBps,
                encoderActualWindowMs: encodedOutput?.actualWindowMs,
                encodedFrameBytesP50: encodedOutput?.frameBytesP50,
                encodedFrameBytesP95: encodedOutput?.frameBytesP95,
                encodedFrameBytesP99: encodedOutput?.frameBytesP99,
                encodedKeyframeBytesP50: encodedOutput?.keyframeBytesP50,
                encodedKeyframeBytesP95: encodedOutput?.keyframeBytesP95,
                encodedKeyframeBytesP99: encodedOutput?.keyframeBytesP99,
                encoderRateControlStrategy: encodedOutput?.rateControlStrategy,
                encoderRateLimitBytes: encodedOutput?.rateLimitBytes,
                encoderRateLimitWindowMs: encodedOutput?.rateLimitWindowMs,
                effectiveStreamScale: Double(streamScale),
                adaptiveStreamScaleReason: adaptiveStreamScaleReason,
                encoderRetuneValidationResult: rateControlRetuneValidationResult,
                encoderKeyframeForRetuneCount: keyframeForRetuneCount,
                encoderSessionRecreationCount: encoderSessionRecreationCount,
                requestedTargetBitrate: requestedTargetBitrate,
                bitrateAdaptationCeiling: bitrateAdaptationCeiling,
                startupBitrate: startupBitrate,
                realtimeBitrateCeiling: realtimeRuntimeBitrateCeilingBps,
                realtimePressureState: realtimePressureState.rawValue,
                realtimePressureReason: realtimePressureReason,
                awdlPolicyState: awdlPolicy?.state.rawValue,
                awdlPolicyTrigger: awdlPolicy?.trigger.rawValue,
                awdlSelectedLever: awdlPolicy?.selectedLever.rawValue,
                awdlPlayoutDelayMs: awdlPolicy?.playoutDelayMs,
                awdlResolutionScale: awdlPolicy?.resolutionScale,
                awdlQualityReductionAllowed: awdlPolicy?.qualityReductionAllowed,
                awdlHostPacingBudgetBps: awdlPolicy?.hostPacingBudgetBps,
                captureAdmissionDrops: captureDroppedIntervalCount,
                frameBudgetMs: frameBudgetMs,
                averageEncodeMs: resolvedAverageEncodeMs,
                captureIngressFPS: lastCaptureIngressFPS,
                captureFPS: lastCaptureFPS,
                encodeAttemptFPS: lastEncodeAttemptFPS,
                captureCadence: captureCadenceMetrics,
                sendQueueBytes: packetTelemetry?.queuedBytes,
                sendStartDelayAverageMs: packetTelemetry?.sendStartDelayAverageMs,
                sendStartDelayMaxMs: packetTelemetry?.sendStartDelayMaxMs,
                sendCompletionAverageMs: packetTelemetry?.sendCompletionAverageMs,
                sendCompletionMaxMs: packetTelemetry?.sendCompletionMaxMs,
                nonKeyframeSendStartDelayMaxMs: packetTelemetry?.nonKeyframeSendStartDelayMaxMs,
                nonKeyframeSendCompletionMaxMs: packetTelemetry?.nonKeyframeSendCompletionMaxMs,
                packetPacerAverageSleepMs: packetTelemetry?.packetPacerSleepAverageMs,
                packetPacerTotalSleepMs: packetTelemetry?.packetPacerSleepTotalMs,
                packetPacerMaxSleepMs: packetTelemetry?.packetPacerSleepMaxMs,
                packetPacerFrameMaxSleepMs: packetTelemetry?.packetPacerFrameMaxSleepMs,
                mediaMaxPacketSize: mediaMaxPacketSize,
                mediaSendProfile: mediaSendProfileRawValue,
                stalePacketDrops: packetTelemetry?.stalePacketDrops,
                senderLocalDeadlineDrops: packetTelemetry?.senderLocalDeadlineDrops,
                generationAbortDrops: packetTelemetry?.generationAbortDrops,
                nonKeyframeHoldDrops: packetTelemetry?.nonKeyframeHoldDrops,
                queuedUnreliableDeadlineExpiredDrops: packetTelemetry?.queuedUnreliableDeadlineExpiredDrops,
                queuedUnreliableQueueLimitDrops: packetTelemetry?.queuedUnreliableQueueLimitDrops,
                queuedUnreliableSupersededDrops: packetTelemetry?.queuedUnreliableSupersededDrops,
                queuedUnreliableUnsupportedTransportDrops: packetTelemetry?.queuedUnreliableUnsupportedTransportDrops,
                queuedUnreliableClosedDrops: packetTelemetry?.queuedUnreliableClosedDrops,
                queuedUnreliablePendingPackets: packetTelemetry?.queuedUnreliablePendingPackets,
                queuedUnreliableOutstandingPackets: packetTelemetry?.queuedUnreliableOutstandingPackets,
                queuedUnreliableQueuedBytes: packetTelemetry?.queuedUnreliableQueuedBytes,
                queuedUnreliablePendingPacketMax: packetTelemetry?.queuedUnreliablePendingPacketMax,
                queuedUnreliableOutstandingPacketMax: packetTelemetry?.queuedUnreliableOutstandingPacketMax,
                queuedUnreliableQueuedBytesMax: packetTelemetry?.queuedUnreliableQueuedBytesMax,
                queuedUnreliableEnqueuedCount: packetTelemetry?.queuedUnreliableEnqueuedCount,
                queuedUnreliableSentCount: packetTelemetry?.queuedUnreliableSentCount,
                queuedUnreliableCompletedCount: packetTelemetry?.queuedUnreliableCompletedCount,
                queuedUnreliableDroppedCount: packetTelemetry?.queuedUnreliableDroppedCount,
                queuedUnreliableErrorCount: packetTelemetry?.queuedUnreliableErrorCount,
                queuedUnreliableQueueDwellP50Ms: packetTelemetry?.queuedUnreliableQueueDwellP50Ms,
                queuedUnreliableQueueDwellP95Ms: packetTelemetry?.queuedUnreliableQueueDwellP95Ms,
                queuedUnreliableQueueDwellP99Ms: packetTelemetry?.queuedUnreliableQueueDwellP99Ms,
                queuedUnreliableSendGapP50Ms: packetTelemetry?.queuedUnreliableSendGapP50Ms,
                queuedUnreliableSendGapP95Ms: packetTelemetry?.queuedUnreliableSendGapP95Ms,
                queuedUnreliableSendGapP99Ms: packetTelemetry?.queuedUnreliableSendGapP99Ms,
                queuedUnreliableContentProcessedP50Ms: packetTelemetry?.queuedUnreliableContentProcessedP50Ms,
                queuedUnreliableContentProcessedP95Ms: packetTelemetry?.queuedUnreliableContentProcessedP95Ms,
                queuedUnreliableContentProcessedP99Ms: packetTelemetry?.queuedUnreliableContentProcessedP99Ms,
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
                tenBitDisplayP3Validated: Self.measuredTenBitDisplayP3Validation(
                    coverageStatus: displayP3CoverageStatus,
                    captureIsTenBitP010: captureValidation?.isTenBitP010,
                    captureIsDisplayP3: captureValidation?.isDisplayP3,
                    encoderTenBitDisplayP3Validated: encoderValidation?.tenBitDisplayP3Validated
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

    private struct CaptureValidationSnapshot {
        let pixelFormat: String
        let colorPrimaries: String?
        let isTenBitP010: Bool
        let isDisplayP3: Bool?
    }

    private func captureValidationSnapshot() -> CaptureValidationSnapshot? {
        guard let pixelBuffer = lastCapturedFrame?.pixelBuffer else { return nil }
        let pixelFormatType = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let pixelFormat = VideoEncoder.fourCCString(pixelFormatType)
        let isTenBitP010 = pixelFormatType == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange ||
            pixelFormatType == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        let colorPrimaries = MirageCVBufferAttachments.string(pixelBuffer, key: kCVImageBufferColorPrimariesKey)
        let transferFunction = MirageCVBufferAttachments.string(pixelBuffer, key: kCVImageBufferTransferFunctionKey)
        let yCbCrMatrix = MirageCVBufferAttachments.string(pixelBuffer, key: kCVImageBufferYCbCrMatrixKey)
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
            isTenBitP010: isTenBitP010,
            isDisplayP3: isDisplayP3
        )
    }

    private func applyUltraValidationDowngradeIfNeeded(
        _ encoderValidation: VideoEncoder.RuntimeValidationSnapshot?
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
    static func measuredTenBitDisplayP3Validation(
        coverageStatus: MirageMedia.MirageDisplayP3CoverageStatus?,
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
        encoder: VideoEncoder.RuntimeValidationSnapshot?
    ) -> MirageMedia.MirageDisplayP3CoverageStatus? {
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

}

#endif
