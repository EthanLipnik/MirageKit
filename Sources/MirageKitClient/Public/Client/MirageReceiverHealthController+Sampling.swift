//
//  MirageReceiverHealthController+Sampling.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/9/26.
//

import Foundation

struct ReceiverHealthSample {
    let hasSevereTransportPressure: Bool
    let hasTransportPressure: Bool
    let hasProvenTransportLoss: Bool
    let hasReceiverMediaDeliveryFailure: Bool
    let isTransportClean: Bool
    let allowsProbePromotion: Bool
    let suppressesProbePromotion: Bool
    let transportPressureReason: String?
}

struct ReceiverPendingPromotion: Equatable {
    let previousBitrateBps: Int
    let targetBitrateBps: Int
    var cleanSampleCount: Int
    let startedAt: CFAbsoluteTime
}

struct ReceiverTransportPressureContext {
    let queueBytes: Int
    let queueStress: Bool
    let queueSevere: Bool
    let sendStartDelayAverageMs: Double
    let sendCompletionAverageMs: Double
    let sendDelayStress: Bool
    let sendDelaySevere: Bool
    let packetPacerAverageSleepMs: Double
    let pairedPacerStress: Bool
    let pairedPacerSevere: Bool
    let transportDropCount: UInt64
    let dropStress: Bool
    let dropSevere: Bool
    let clientIncompleteFrameTimeouts: UInt64
    let clientIncompleteFrameNoProgressTimeouts: UInt64
    let clientIncompleteFrameLifetimeTimeouts: UInt64
    let clientMissingFragmentTimeouts: UInt64
    let clientForwardGapTimeouts: UInt64
    let clientFragmentLossStress: Bool
    let clientFragmentLossSevere: Bool
}

extension MirageReceiverHealthController {
    static func sample(
        from snapshot: MirageClientMetricsSnapshot,
        minimumHealthyFrameRate: Int? = nil
    ) -> ReceiverHealthSample {
        guard snapshot.hasHostMetrics else {
            return ReceiverHealthSample(
                hasSevereTransportPressure: false,
                hasTransportPressure: false,
                hasProvenTransportLoss: false,
                hasReceiverMediaDeliveryFailure: false,
                isTransportClean: false,
                allowsProbePromotion: false,
                suppressesProbePromotion: true,
                transportPressureReason: nil
            )
        }

        _ = minimumHealthyFrameRate
        let queueBytes = max(0, snapshot.hostSendQueueBytes ?? 0)
        let sendStartDelayAverageMs = max(0, snapshot.hostSendStartDelayAverageMs ?? 0)
        let sendCompletionAverageMs = max(0, snapshot.hostSendCompletionAverageMs ?? 0)
        let packetPacerAverageSleepMs = max(0, snapshot.hostPacketPacerAverageSleepMs ?? 0)
        let remoteTransportDropCount = snapshot.hostStalePacketDrops ?? 0
        let transportDropCount = remoteTransportDropCount +
            (snapshot.hostSenderLocalDeadlineDrops ?? 0)
        let clientIncompleteFrameTimeouts = snapshot.clientReassemblerIncompleteFrameTimeouts
        let clientIncompleteFrameNoProgressTimeouts =
            snapshot.clientReassemblerIncompleteFrameNoProgressTimeouts
        let clientIncompleteFrameLifetimeTimeouts =
            snapshot.clientReassemblerIncompleteFrameLifetimeTimeouts
        let clientMissingFragmentTimeouts = snapshot.clientReassemblerMissingFragmentTimeouts
        let clientForwardGapTimeouts = snapshot.clientReassemblerForwardGapTimeouts
        let receiverMediaDeliveryFailureCount = clientIncompleteFrameTimeouts + clientForwardGapTimeouts
        let receiverMediaDeliveryFailure = receiverMediaDeliveryFailureCount > 0

        let queueStress = queueBytes >= Self.sendQueueStressBytes
        let queueSevere = queueBytes >= Self.sendQueueSevereBytes
        let sendDelayStress = sendStartDelayAverageMs >= Self.sendStartDelayStressMs ||
            sendCompletionAverageMs >= Self.sendCompletionStressMs
        let sendDelaySevere = sendStartDelayAverageMs >= Self.sendStartDelaySevereMs ||
            sendCompletionAverageMs >= Self.sendCompletionSevereMs
        let pacerStress = packetPacerAverageSleepMs >= Self.packetPacerStressMs
        let pacerSevere = packetPacerAverageSleepMs >= Self.packetPacerSevereMs
        let dropStress = transportDropCount >= Self.transportDropStressCount
        let dropSevere = transportDropCount >= Self.transportDropSevereCount
        let clientFragmentLossStress = receiverMediaDeliveryFailure ||
            clientIncompleteFrameTimeouts >= Self.clientFragmentLossFrameStressCount ||
            clientForwardGapTimeouts > 0 ||
            clientMissingFragmentTimeouts >= Self.clientMissingFragmentStressCount
        let clientFragmentLossSevere = clientIncompleteFrameTimeouts >= Self.clientFragmentLossFrameSevereCount ||
            clientForwardGapTimeouts >= Self.clientForwardGapTimeoutSevereCount ||
            clientMissingFragmentTimeouts >= Self.clientMissingFragmentSevereCount

        let pairedPacerStress = pacerStress && (queueStress || dropStress)
        let pairedPacerSevere = pacerSevere && (queueSevere || dropSevere)
        let keyframeAssemblyInProgress = snapshot.clientReassemblerPendingKeyframeCount > 0
        let severeTransportPressure = queueSevere ||
            sendDelaySevere ||
            dropSevere ||
            clientFragmentLossSevere ||
            pairedPacerSevere
        let sustainedTransportPressure = queueStress ||
            sendDelaySevere ||
            dropStress ||
            clientFragmentLossStress ||
            pairedPacerStress
        let transportPressureReason = Self.transportPressureReason(
            ReceiverTransportPressureContext(
                queueBytes: queueBytes,
                queueStress: queueStress,
                queueSevere: queueSevere,
                sendStartDelayAverageMs: sendStartDelayAverageMs,
                sendCompletionAverageMs: sendCompletionAverageMs,
                sendDelayStress: sendDelayStress,
                sendDelaySevere: sendDelaySevere,
                packetPacerAverageSleepMs: packetPacerAverageSleepMs,
                pairedPacerStress: pairedPacerStress,
                pairedPacerSevere: pairedPacerSevere,
                transportDropCount: transportDropCount,
                dropStress: dropStress,
                dropSevere: dropSevere,
                clientIncompleteFrameTimeouts: clientIncompleteFrameTimeouts,
                clientIncompleteFrameNoProgressTimeouts: clientIncompleteFrameNoProgressTimeouts,
                clientIncompleteFrameLifetimeTimeouts: clientIncompleteFrameLifetimeTimeouts,
                clientMissingFragmentTimeouts: clientMissingFragmentTimeouts,
                clientForwardGapTimeouts: clientForwardGapTimeouts,
                clientFragmentLossStress: clientFragmentLossStress,
                clientFragmentLossSevere: clientFragmentLossSevere
            )
        )

        let suppressesProbePromotion = queueStress ||
            transportDropCount > 0 ||
            clientFragmentLossStress ||
            sendDelayStress ||
            pairedPacerStress ||
            keyframeAssemblyInProgress

        return ReceiverHealthSample(
            hasSevereTransportPressure: severeTransportPressure,
            hasTransportPressure: severeTransportPressure || sustainedTransportPressure,
            hasProvenTransportLoss: remoteTransportDropCount >= Self.transportDropStressCount ||
                receiverMediaDeliveryFailure ||
                clientFragmentLossStress,
            hasReceiverMediaDeliveryFailure: receiverMediaDeliveryFailure,
            isTransportClean: !severeTransportPressure && !sustainedTransportPressure && !keyframeAssemblyInProgress,
            allowsProbePromotion: !suppressesProbePromotion,
            suppressesProbePromotion: suppressesProbePromotion,
            transportPressureReason: transportPressureReason
        )
    }

    private static func transportPressureReason(_ context: ReceiverTransportPressureContext) -> String? {
        if context.queueSevere || context.queueStress {
            return "host send queue \(formatBytes(context.queueBytes))"
        }
        if context.dropSevere || context.dropStress {
            return "host packet drops \(context.transportDropCount)"
        }
        if context.clientFragmentLossSevere || context.clientFragmentLossStress {
            return "client fragment loss frames=\(context.clientIncompleteFrameTimeouts) " +
                "noProgress=\(context.clientIncompleteFrameNoProgressTimeouts) " +
                "lifetime=\(context.clientIncompleteFrameLifetimeTimeouts) " +
                "forwardGaps=\(context.clientForwardGapTimeouts) " +
                "missing=\(context.clientMissingFragmentTimeouts)"
        }
        if context.sendDelaySevere || context.sendDelayStress {
            let startText = Self.formatMilliseconds(context.sendStartDelayAverageMs)
            let completionText = Self.formatMilliseconds(context.sendCompletionAverageMs)
            return "host send delay start=\(startText) completion=\(completionText)"
        }
        if context.pairedPacerSevere || context.pairedPacerStress {
            return "packet pacer \(formatMilliseconds(context.packetPacerAverageSleepMs)) with queue/drop pressure"
        }
        return nil
    }

    private static func formatBytes(_ bytes: Int) -> String {
        guard bytes >= 1024 else { return "\(bytes)B" }
        let kib = Double(bytes) / 1024.0
        if kib < 1024 {
            return "\(kib.formatted(.number.precision(.fractionLength(1))))KiB"
        }
        let mib = kib / 1024.0
        return "\(mib.formatted(.number.precision(.fractionLength(2))))MiB"
    }

    private static func formatMilliseconds(_ milliseconds: Double) -> String {
        "\(milliseconds.formatted(.number.precision(.fractionLength(1))))ms"
    }

    func isFastStartActive(now: CFAbsoluteTime) -> Bool {
        guard let sessionStartedAt else { return false }
        return now - sessionStartedAt < Self.fastStartDurationSeconds
    }

    func probeCooldown(success: Bool, now: CFAbsoluteTime) -> CFAbsoluteTime {
        let fastStartActive = isFastStartActive(now: now)
        return switch (success, fastStartActive) {
        case (true, true):
            Self.fastStartSuccessfulProbeCooldownSeconds
        case (true, false):
            Self.successfulProbeCooldownSeconds
        case (false, true):
            Self.fastStartFailedProbeCooldownSeconds
        case (false, false):
            Self.failedProbeCooldownSeconds
        }
    }

    static func worstSnapshot(
        from snapshots: [MirageClientMetricsSnapshot],
        minimumHealthyFrameRate: Int?
    ) -> MirageClientMetricsSnapshot {
        guard let firstSnapshot = snapshots.first else {
            preconditionFailure("Receiver-health sampling requires at least one metrics snapshot.")
        }
        return snapshots.max(by: { lhs, rhs in
            healthPriority(for: lhs, minimumHealthyFrameRate: minimumHealthyFrameRate) <
                healthPriority(for: rhs, minimumHealthyFrameRate: minimumHealthyFrameRate)
        }) ?? firstSnapshot
    }

    private static func healthPriority(
        for snapshot: MirageClientMetricsSnapshot,
        minimumHealthyFrameRate: Int?
    ) -> Int {
        let sample = sample(
            from: snapshot,
            minimumHealthyFrameRate: minimumHealthyFrameRate
        )
        var score = 0
        if sample.hasSevereTransportPressure {
            score += 1000
        } else if sample.hasTransportPressure {
            score += 600
        }
        if sample.suppressesProbePromotion {
            score += 100
        }
        if !sample.allowsProbePromotion {
            score += 50
        }
        return score
    }
}
