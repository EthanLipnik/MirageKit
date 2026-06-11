//
//  StreamContext+TransportBurstPressure.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 6/3/26.
//

import CoreFoundation
import Foundation

#if os(macOS)
extension StreamContext {
    func applyQueuedUnreliableBurstPressureIfNeeded(
        _ telemetry: StreamPacketSender.TelemetrySnapshot?,
        now: CFAbsoluteTime
    ) async {
        guard runtimeQualityAdjustmentEnabled || mediaPathProfile.usesAwdlRadioPolicy,
              let telemetry else {
            return
        }

        let sendGapP99Ms = telemetry.queuedUnreliableSendGapP99Ms ?? 0
        let queueDwellP99Ms = telemetry.queuedUnreliableQueueDwellP99Ms ?? 0
        let contentProcessedP99Ms = telemetry.queuedUnreliableContentProcessedP99Ms ?? 0
        let worstP99Ms = max(sendGapP99Ms, max(queueDwellP99Ms, contentProcessedP99Ms))
        let outstandingMax = telemetry.queuedUnreliableOutstandingPacketMax ??
            telemetry.queuedUnreliableOutstandingPackets ??
            0
        let pendingMax = telemetry.queuedUnreliablePendingPacketMax ??
            telemetry.queuedUnreliablePendingPackets ??
            0
        let queuedUnreliableBytes = max(
            telemetry.queuedUnreliableQueuedBytes ?? 0,
            telemetry.queuedUnreliableQueuedBytesMax ?? 0
        )
        let localQueuedBytes = telemetry.queuedBytes
        let softQueuedByteThreshold = min(queuePressureBytes, max(384 * 1024, queuePressureBytes / 2))
        let sendGapQueuedByteThreshold = max(32 * 1024, maxPayloadSize * 4)

        let hasSendGapOccupancy = outstandingMax >= 16 ||
            pendingMax >= 4 ||
            queuedUnreliableBytes >= sendGapQueuedByteThreshold ||
            localQueuedBytes >= sendGapQueuedByteThreshold
        let hasTimingPressure = queueDwellP99Ms >= 180 ||
            contentProcessedP99Ms >= 180 ||
            (sendGapP99Ms >= 180 && hasSendGapOccupancy)
        let hasOccupancyPressure = outstandingMax >= 40 ||
            pendingMax >= 16 ||
            queuedUnreliableBytes >= softQueuedByteThreshold ||
            localQueuedBytes >= queuePressureBytes
        let hasSoftPressure = hasTimingPressure || hasOccupancyPressure
        guard hasSoftPressure else { return }

        let hasSevereTimingPressure = queueDwellP99Ms >= 320 ||
            contentProcessedP99Ms >= 320 ||
            (sendGapP99Ms >= 320 &&
                (pendingMax >= 8 ||
                    outstandingMax >= 32 ||
                    queuedUnreliableBytes >= softQueuedByteThreshold ||
                    localQueuedBytes >= queuePressureBytes))
        let hasSeverePressure = hasSevereTimingPressure ||
            outstandingMax >= 48 ||
            pendingMax >= 32 ||
            queuedUnreliableBytes >= queuePressureBytes ||
            localQueuedBytes >= max(queuePressureBytes, maxQueuedBytes / 2)

        let decision = adaptivePFrameController.recordTransportBacklogPressure(
            severe: hasSeverePressure,
            currentBitrateBps: currentTargetBitrateBps ?? encoderConfig.bitrate,
            requestedTargetBitrateBps: requestedTargetBitrate,
            startupCeilingBps: bitrateAdaptationCeiling ?? startupBitrate,
            minimumBitrateFloorBps: realtimeMinimumBitrateFloorBps,
            currentFrameRate: currentFrameRate,
            maxPayloadSize: maxPayloadSize,
            currentQuality: activeQuality,
            qualityFloor: qualityFloor,
            steadyQualityCeiling: configuredQualityCeiling,
            latencyMode: latencyMode,
            mediaPathProfile: mediaPathProfile,
            receiverPlayoutDelayTargetMs: receiverPlayoutDelayTargetMs,
            awdlQualityReductionAllowed: currentAwdlQualityReductionAllowed(),
            now: now
        )
        guard let decision else { return }
        await applyFrameBudgetDecision(decision, now: now)

        MirageLogger.metrics(
            "event=transport_backlog_pressure stream=\(streamID) state=\(decision.state.rawValue) " +
                "worstP99Ms=\((worstP99Ms * 10).rounded() / 10) " +
                "sendGapP99Ms=\((sendGapP99Ms * 10).rounded() / 10) " +
                "queueDwellP99Ms=\((queueDwellP99Ms * 10).rounded() / 10) " +
                "contentP99Ms=\((contentProcessedP99Ms * 10).rounded() / 10) " +
                "outstandingMax=\(outstandingMax) pendingMax=\(pendingMax) " +
                "loomQueuedBytes=\(queuedUnreliableBytes) senderQueuedBytes=\(localQueuedBytes) " +
                "targetBitrate=\(decision.targetBitrateBps) quality=\(decision.quality)"
        )
    }
}
#endif
