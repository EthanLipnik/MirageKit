//
//  StreamPacketSender+Telemetry.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/9/26.
//

import CoreFoundation

#if os(macOS)

extension StreamPacketSender {
    /// Current telemetry counters without resetting the reporting window.
    var telemetrySnapshot: TelemetrySnapshot {
        let queueSnapshot = queueLock.withLock {
            (
                queuedBytes: self.queuedBytes,
                staleDrops: queuedStalePacketDropCount,
                senderLocalDeadlineDrops: queuedSenderLocalDeadlineDropCount,
                generationDrops: queuedGenerationAbortDropCount,
                nonKeyframeHoldDrops: queuedNonKeyframeHoldDropCount
            )
        }
        return TelemetrySnapshot(
            queuedBytes: queueSnapshot.queuedBytes,
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
            generationAbortDrops: generationAbortDropCount + queueSnapshot.generationDrops,
            nonKeyframeHoldDrops: nonKeyframeHoldDropCount + queueSnapshot.nonKeyframeHoldDrops
        )
    }

    /// Returns current telemetry and resets per-window counters.
    func consumeTelemetrySnapshot() -> TelemetrySnapshot {
        let snapshot = telemetrySnapshot
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
        generationAbortDropCount = 0
        nonKeyframeHoldDropCount = 0
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
}

#endif
