//
//  StreamContext+TransportBurstPressure.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 6/3/26.
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
        let outstandingMax = telemetry.queuedUnreliableOutstandingPackets ?? 0
        let pendingMax = telemetry.queuedUnreliablePendingPackets ?? 0
        let queuedUnreliableBytes = telemetry.queuedUnreliableQueuedBytes ?? 0
        let localQueuedBytes = telemetry.queuedBytes
        let softQueuedByteThreshold = min(queuePressureBytes, max(384 * 1024, queuePressureBytes / 2))
        let sendGapQueuedByteThreshold = max(32 * 1024, maxPayloadSize * 4)

        let hasSendGapOccupancy = pendingMax >= 4 ||
            queuedUnreliableBytes >= sendGapQueuedByteThreshold ||
            localQueuedBytes >= sendGapQueuedByteThreshold
        let hasTimingPressure = hasSendGapOccupancy &&
            (queueDwellP99Ms >= 180 ||
                contentProcessedP99Ms >= 180 ||
                sendGapP99Ms >= 180)
        let hasOccupancyPressure = pendingMax >= 16 ||
            queuedUnreliableBytes >= softQueuedByteThreshold ||
            localQueuedBytes >= queuePressureBytes
        let hasSoftPressure = hasTimingPressure || hasOccupancyPressure
        guard hasSoftPressure else { return }

        let hasSevereTimingPressure = (pendingMax >= 8 ||
            queuedUnreliableBytes >= softQueuedByteThreshold ||
            localQueuedBytes >= queuePressureBytes) &&
            (queueDwellP99Ms >= 320 ||
                contentProcessedP99Ms >= 320 ||
                sendGapP99Ms >= 320)
        let hasSeverePressure = hasSevereTimingPressure ||
            pendingMax >= 32 ||
            queuedUnreliableBytes >= queuePressureBytes ||
            localQueuedBytes >= max(queuePressureBytes, maxQueuedBytes / 2)

        MirageLogger.metrics(
            "event=transport_backlog_pressure stream=\(streamID) " +
                "state=\(hasSeverePressure ? "severe" : "pressured") action=evidence-only " +
                "worstP99Ms=\((worstP99Ms * 10).rounded() / 10) " +
                "sendGapP99Ms=\((sendGapP99Ms * 10).rounded() / 10) " +
                "queueDwellP99Ms=\((queueDwellP99Ms * 10).rounded() / 10) " +
                "contentP99Ms=\((contentProcessedP99Ms * 10).rounded() / 10) " +
                "outstandingMax=\(outstandingMax) pendingMax=\(pendingMax) " +
                "loomQueuedBytes=\(queuedUnreliableBytes) senderQueuedBytes=\(localQueuedBytes) " +
                "targetBitrate=\(currentTargetBitrateBps ?? encoderConfig.bitrate ?? 0) quality=\(activeQuality)"
        )
    }
}
#endif
