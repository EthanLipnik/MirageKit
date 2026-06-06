//
//  StreamPacketSender+Telemetry.swift
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
import CoreFoundation

#if os(macOS)

extension StreamPacketSender {
    /// Current telemetry counters without resetting the reporting window.
    var telemetrySnapshot: TelemetrySnapshot {
        telemetrySnapshot(queuedUnreliableDiagnostics: nil)
    }

    /// Current telemetry counters with optional queued-unreliable diagnostics.
    func telemetrySnapshot(
        queuedUnreliableDiagnostics: MirageQueuedUnreliableSendDiagnostics?
    ) -> TelemetrySnapshot {
        let queueSnapshot = queueLock.withLock {
            let freshness = freshnessSnapshotLocked(now: CFAbsoluteTimeGetCurrent())
            return (
                queuedBytes: self.queuedBytes,
                unstartedPFrameCount: freshness.unstartedPFrameCount,
                oldestUnstartedPFrameAgeMs: freshness.oldestUnstartedPFrameAgeMs,
                oldestUnstartedPFrameLatenessMs: freshness.oldestUnstartedPFrameLatenessMs,
                staleDrops: queuedStalePacketDropCount,
                senderLocalDeadlineDrops: queuedSenderLocalDeadlineDropCount,
                generationDrops: queuedGenerationAbortDropCount,
                nonKeyframeHoldDrops: queuedNonKeyframeHoldDropCount
            )
        }
        return TelemetrySnapshot(
            queuedBytes: queueSnapshot.queuedBytes,
            unstartedPFrameCount: queueSnapshot.unstartedPFrameCount,
            oldestUnstartedPFrameAgeMs: queueSnapshot.oldestUnstartedPFrameAgeMs,
            oldestUnstartedPFrameLatenessMs: queueSnapshot.oldestUnstartedPFrameLatenessMs,
            lateReservedPFrameStreak: lateReservedPFrameStreak,
            sendStartDelayAverageMs: average(total: sendStartDelayTotalMs, count: sendStartDelayCount),
            sendStartDelayMaxMs: sendStartDelayMaxMs,
            sendCompletionAverageMs: average(total: sendCompletionTotalMs, count: sendCompletionCount),
            sendCompletionMaxMs: sendCompletionMaxMs,
            nonKeyframeSendStartDelayMaxMs: nonKeyframeSendStartDelayMaxMs,
            nonKeyframeSendCompletionMaxMs: nonKeyframeSendCompletionMaxMs,
            packetPacerSleepAverageMs: average(total: Double(pacerSleepTotalMs), count: pacerSleepPacketCount),
            packetPacerSleepTotalMs: pacerSleepTotalMs,
            packetPacerSleepMaxMs: pacerSleepMaxMs,
            packetPacerFrameMaxSleepMs: pacerFrameSleepMaxMs,
            stalePacketDrops: stalePacketDropCount + queueSnapshot.staleDrops,
            senderLocalDeadlineDrops: queueSnapshot.senderLocalDeadlineDrops,
            lateNonKeyframeSends: lateNonKeyframeSendCount,
            generationAbortDrops: generationAbortDropCount + queueSnapshot.generationDrops,
            nonKeyframeHoldDrops: nonKeyframeHoldDropCount + queueSnapshot.nonKeyframeHoldDrops,
            queuedUnreliableDeadlineExpiredDrops: queuedUnreliableDropCounts.deadlineExpired,
            queuedUnreliableQueueLimitDrops: queuedUnreliableDropCounts.queueLimit,
            queuedUnreliableSupersededDrops: queuedUnreliableDropCounts.superseded,
            queuedUnreliableUnsupportedTransportDrops: queuedUnreliableDropCounts.unsupportedTransport,
            queuedUnreliableClosedDrops: queuedUnreliableDropCounts.closed,
            queuedUnreliablePendingPackets: queuedUnreliableDiagnostics?.pendingPackets,
            queuedUnreliableOutstandingPackets: queuedUnreliableDiagnostics?.outstandingPackets,
            queuedUnreliableQueuedBytes: queuedUnreliableDiagnostics?.queuedBytes,
            queuedUnreliablePendingPacketMax: queuedUnreliableDiagnostics?.pendingPacketMax,
            queuedUnreliableOutstandingPacketMax: queuedUnreliableDiagnostics?.outstandingPacketMax,
            queuedUnreliableQueuedBytesMax: queuedUnreliableDiagnostics?.queuedBytesMax,
            queuedUnreliableEnqueuedCount: queuedUnreliableDiagnostics?.enqueuedCount,
            queuedUnreliableSentCount: queuedUnreliableDiagnostics?.sentCount,
            queuedUnreliableCompletedCount: queuedUnreliableDiagnostics?.completedCount,
            queuedUnreliableDroppedCount: queuedUnreliableDiagnostics?.droppedCount,
            queuedUnreliableErrorCount: queuedUnreliableDiagnostics?.errorCount,
            queuedUnreliableQueueDwellP50Ms: queuedUnreliableDiagnostics?.queueDwellP50Ms,
            queuedUnreliableQueueDwellP95Ms: queuedUnreliableDiagnostics?.queueDwellP95Ms,
            queuedUnreliableQueueDwellP99Ms: queuedUnreliableDiagnostics?.queueDwellP99Ms,
            queuedUnreliableSendGapP50Ms: queuedUnreliableDiagnostics?.sendGapP50Ms,
            queuedUnreliableSendGapP95Ms: queuedUnreliableDiagnostics?.sendGapP95Ms,
            queuedUnreliableSendGapP99Ms: queuedUnreliableDiagnostics?.sendGapP99Ms,
            queuedUnreliableContentProcessedP50Ms: queuedUnreliableDiagnostics?.contentProcessedP50Ms,
            queuedUnreliableContentProcessedP95Ms: queuedUnreliableDiagnostics?.contentProcessedP95Ms,
            queuedUnreliableContentProcessedP99Ms: queuedUnreliableDiagnostics?.contentProcessedP99Ms
        )
    }

    /// Returns current telemetry and resets per-window counters.
    func consumeTelemetrySnapshot() -> TelemetrySnapshot {
        let snapshot = telemetrySnapshot
        resetTelemetryWindow()
        return snapshot
    }

    /// Returns current telemetry with transport-owned queued-unreliable diagnostics and resets per-window counters.
    func consumeTelemetrySnapshot(
        queuedUnreliableProfile: MirageMedia.MirageMediaSendProfile?
    ) async -> TelemetrySnapshot {
        let queuedDiagnostics: MirageQueuedUnreliableSendDiagnostics? = if let queuedUnreliableProfile,
                                                                           let queuedUnreliableDiagnosticsProvider {
            await queuedUnreliableDiagnosticsProvider(queuedUnreliableProfile)
        } else {
            nil
        }
        let snapshot = telemetrySnapshot(queuedUnreliableDiagnostics: queuedDiagnostics)
        resetTelemetryWindow()
        return snapshot
    }

    /// Clears per-window telemetry while preserving current queue depth.
    func resetTelemetryWindow() {
        sendStartDelayTotalMs = 0
        sendStartDelayMaxMs = 0
        sendStartDelayCount = 0
        sendCompletionTotalMs = 0
        sendCompletionMaxMs = 0
        sendCompletionCount = 0
        nonKeyframeSendStartDelayMaxMs = 0
        nonKeyframeSendCompletionMaxMs = 0
        resetPacketPacerTelemetryCounters()
        stalePacketDropCount = 0
        lateNonKeyframeSendCount = 0
        generationAbortDropCount = 0
        nonKeyframeHoldDropCount = 0
        queuedUnreliableDropCounts = QueuedUnreliableDropCounts()
        queueLock.withLock {
            queuedStalePacketDropCount = 0
            queuedSenderLocalDeadlineDropCount = 0
            queuedGenerationAbortDropCount = 0
            queuedNonKeyframeHoldDropCount = 0
        }
    }

    /// Average for telemetry counters that may have no samples in the reporting window.
    func average(total: Double, count: some BinaryInteger) -> Double {
        guard count > 0 else { return 0 }
        return total / Double(count)
    }

    /// Clears packet-pacer counters that belong to the telemetry reporting window.
    func resetPacketPacerTelemetryCounters() {
        pacerSleepTotalMs = 0
        pacerSleepMaxMs = 0
        pacerFrameSleepMaxMs = 0
        pacerSleepPacketCount = 0
    }

    /// Adds one packet-pacer sleep sample to telemetry counters.
    func recordPacketPacerSleep(_ sample: PacketPacingSleepSample) {
        guard sample.totalMs > 0 || sample.maxMs > 0 else { return }
        pacerSleepTotalMs += sample.totalMs
        pacerSleepMaxMs = max(pacerSleepMaxMs, sample.maxMs)
        pacerSleepPacketCount += 1
    }

    /// Records frame-level pacing delay from a completed send pass.
    func recordFramePacerSleep(totalMs: Int, maxMs: Int) {
        guard totalMs > 0 || maxMs > 0 else { return }
        pacerFrameSleepMaxMs = max(pacerFrameSleepMaxMs, maxMs)
    }

    /// Records the delay between encode completion and first packet submission.
    func recordSendStartDelay(item: WorkItem, now: CFAbsoluteTime) {
        let delayMs = max(0, (now - item.encodedAt) * 1000)
        sendStartDelayTotalMs += delayMs
        sendStartDelayMaxMs = max(sendStartDelayMaxMs, delayMs)
        sendStartDelayCount &+= 1
        if !item.isKeyframe {
            nonKeyframeSendStartDelayMaxMs = max(nonKeyframeSendStartDelayMaxMs, delayMs)
        }
    }

    /// Records the delay between encode completion and transport completion.
    func recordSendCompletion(item: WorkItem, completedAt: CFAbsoluteTime) {
        let completionMs = max(0, (completedAt - item.encodedAt) * 1000)
        sendCompletionTotalMs += completionMs
        sendCompletionMaxMs = max(sendCompletionMaxMs, completionMs)
        sendCompletionCount &+= 1
        if !item.isKeyframe {
            nonKeyframeSendCompletionMaxMs = max(nonKeyframeSendCompletionMaxMs, completionMs)
        }
    }

    /// Records Loom queued-unreliable drop reasons reported during frame transport.
    func recordQueuedUnreliableDrops(_ counts: QueuedUnreliableDropCounts) {
        guard !counts.isEmpty else { return }
        queuedUnreliableDropCounts.merge(counts)
    }
}

#endif
