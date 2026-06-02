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
    let hasReceiverMediaLatencyPressure: Bool
    let hasSevereReceiverMediaLatencyPressure: Bool
    let isTransportClean: Bool
    let allowsProbePromotion: Bool
    let suppressesProbePromotion: Bool
    let transportPressureReason: String?
}

struct ReceiverPendingPromotion: Equatable {
    let previousBitrateBps: Int
    let targetBitrateBps: Int
    let qualityRecovery: Bool
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
    let clientPFrameCompletionLatencyP95Ms: Double
    let clientLatePFrameCompletionCount: UInt64
    let clientPFrameLatencyStress: Bool
    let clientPFrameLatencySevere: Bool
    let clientFragmentLossStress: Bool
    let clientFragmentLossSevere: Bool
    let hostEncodedFPS: Double
    let receivedFPS: Double
    let clientReceivedWorstGapMs: Double
    let clientReceivedFrameIntervalP95Ms: Double
    let clientReceivedFrameIntervalP99Ms: Double
    let receiverDeliveryStress: Bool
    let receiverDeliverySevere: Bool
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
                hasReceiverMediaLatencyPressure: false,
                hasSevereReceiverMediaLatencyPressure: false,
                isTransportClean: false,
                allowsProbePromotion: false,
                suppressesProbePromotion: true,
                transportPressureReason: nil
            )
        }

        let queueBytes = max(0, snapshot.hostSendQueueBytes ?? 0)
        let sendStartDelayAverageMs = max(0, snapshot.hostSendStartDelayAverageMs ?? 0)
        let sendCompletionAverageMs = max(0, snapshot.hostSendCompletionAverageMs ?? 0)
        let packetPacerAverageSleepMs = max(0, snapshot.hostPacketPacerAverageSleepMs ?? 0)
        let remoteTransportDropCount = snapshot.hostTransportPressureDropCount
        let transportDropCount = remoteTransportDropCount
        let clientIncompleteFrameTimeouts = snapshot.clientReassemblerIncompleteFrameTimeouts
        let clientIncompleteFrameNoProgressTimeouts =
            snapshot.clientReassemblerIncompleteFrameNoProgressTimeouts
        let clientIncompleteFrameLifetimeTimeouts =
            snapshot.clientReassemblerIncompleteFrameLifetimeTimeouts
        let clientMissingFragmentTimeouts = snapshot.clientReassemblerMissingFragmentTimeouts
        let clientForwardGapTimeouts = snapshot.clientReassemblerForwardGapTimeouts
        let clientPFrameCompletionLatencyP95Ms = snapshot.clientPFrameCompletionLatencyP95Ms
        let clientLatePFrameCompletionCount = snapshot.clientLatePFrameCompletionCount
        let receiverDeliveryPressure = Self.receiverDeliveryPressure(
            snapshot,
            minimumHealthyFrameRate: minimumHealthyFrameRate
        )
        let receiverMediaDeliveryFailureCount = clientIncompleteFrameTimeouts +
            clientMissingFragmentTimeouts +
            clientForwardGapTimeouts
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
        let clientPFrameLatencyStress = clientPFrameCompletionLatencyP95Ms >= Self.clientPFrameLatencyStressMs ||
            clientLatePFrameCompletionCount >= Self.clientLatePFrameStressCount
        let clientPFrameLatencySevere = clientPFrameCompletionLatencyP95Ms >= Self.clientPFrameLatencySevereMs

        let pairedPacerStress = pacerStress && (queueStress || dropStress)
        let pairedPacerSevere = pacerSevere && (queueSevere || dropSevere)
        let keyframeAssemblyInProgress = snapshot.clientReassemblerPendingKeyframeCount > 0
        let severeTransportPressure = queueSevere ||
            sendDelaySevere ||
            dropSevere ||
            clientFragmentLossSevere ||
            clientPFrameLatencySevere ||
            receiverDeliveryPressure.severe ||
            pairedPacerSevere
        let sustainedTransportPressure = queueStress ||
            sendDelaySevere ||
            dropStress ||
            clientFragmentLossStress ||
            clientPFrameLatencyStress ||
            receiverDeliveryPressure.stress ||
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
                clientPFrameCompletionLatencyP95Ms: clientPFrameCompletionLatencyP95Ms,
                clientLatePFrameCompletionCount: clientLatePFrameCompletionCount,
                clientPFrameLatencyStress: clientPFrameLatencyStress,
                clientPFrameLatencySevere: clientPFrameLatencySevere,
                clientFragmentLossStress: clientFragmentLossStress,
                clientFragmentLossSevere: clientFragmentLossSevere,
                hostEncodedFPS: receiverDeliveryPressure.hostEncodedFPS,
                receivedFPS: receiverDeliveryPressure.receivedFPS,
                clientReceivedWorstGapMs: receiverDeliveryPressure.receivedWorstGapMs,
                clientReceivedFrameIntervalP95Ms: receiverDeliveryPressure.receivedFrameIntervalP95Ms,
                clientReceivedFrameIntervalP99Ms: receiverDeliveryPressure.receivedFrameIntervalP99Ms,
                receiverDeliveryStress: receiverDeliveryPressure.stress,
                receiverDeliverySevere: receiverDeliveryPressure.severe
            )
        )

        let suppressesProbePromotion = queueStress ||
            transportDropCount > 0 ||
            clientFragmentLossStress ||
            clientPFrameLatencyStress ||
            receiverDeliveryPressure.stress ||
            sendDelayStress ||
            pairedPacerStress ||
            keyframeAssemblyInProgress

        return ReceiverHealthSample(
            hasSevereTransportPressure: severeTransportPressure,
            hasTransportPressure: severeTransportPressure || sustainedTransportPressure,
            hasProvenTransportLoss: remoteTransportDropCount >= Self.transportDropStressCount ||
                receiverMediaDeliveryFailure ||
                clientFragmentLossStress ||
                clientPFrameLatencyStress ||
                receiverDeliveryPressure.stress,
            hasReceiverMediaDeliveryFailure: receiverMediaDeliveryFailure,
            hasReceiverMediaLatencyPressure: clientPFrameLatencyStress,
            hasSevereReceiverMediaLatencyPressure: clientPFrameLatencySevere,
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
        if context.clientPFrameLatencySevere || context.clientPFrameLatencyStress {
            return "client p-frame latency p95=\(formatMilliseconds(context.clientPFrameCompletionLatencyP95Ms)) " +
                "late=\(context.clientLatePFrameCompletionCount)"
        }
        if context.receiverDeliverySevere || context.receiverDeliveryStress {
            return "client delivery cadence host=\(formatFPS(context.hostEncodedFPS)) " +
                "received=\(formatFPS(context.receivedFPS)) " +
                "worstGap=\(formatMilliseconds(context.clientReceivedWorstGapMs)) " +
                "p95=\(formatMilliseconds(context.clientReceivedFrameIntervalP95Ms)) " +
                "p99=\(formatMilliseconds(context.clientReceivedFrameIntervalP99Ms))"
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

    private static func formatFPS(_ fps: Double) -> String {
        "\(fps.formatted(.number.precision(.fractionLength(1))))fps"
    }

    private static func receiverDeliveryPressure(
        _ snapshot: MirageClientMetricsSnapshot,
        minimumHealthyFrameRate: Int?
    ) -> (
        stress: Bool,
        severe: Bool,
        hostEncodedFPS: Double,
        receivedFPS: Double,
        receivedWorstGapMs: Double,
        receivedFrameIntervalP95Ms: Double,
        receivedFrameIntervalP99Ms: Double
    ) {
        let targetFrameRate = Double(max(1, minimumHealthyFrameRate ?? snapshot.hostTargetFrameRate))
        let hostEncodedFPS = max(0, snapshot.hostEncodedFPS)
        let receivedFPS = max(0, snapshot.receivedFPS)
        let receiverHasStarted = receivedFPS > 0 || snapshot.decodedFPS > 0 || snapshot.submittedFPS > 0
        guard receiverHasStarted,
              hostEncodedFPS >= targetFrameRate * Self.hostDeliveryCadenceHealthyRatio else {
            return (
                stress: false,
                severe: false,
                hostEncodedFPS: hostEncodedFPS,
                receivedFPS: receivedFPS,
                receivedWorstGapMs: max(0, snapshot.clientReceivedWorstGapMs),
                receivedFrameIntervalP95Ms: max(0, snapshot.clientReceivedFrameIntervalP95Ms),
                receivedFrameIntervalP99Ms: max(0, snapshot.clientReceivedFrameIntervalP99Ms)
            )
        }

        let expectedReceiverFPS = min(targetFrameRate, hostEncodedFPS)
        let cadenceStress = receivedFPS < expectedReceiverFPS * Self.clientReceivedCadenceStressRatio
        let cadenceSevere = receivedFPS < expectedReceiverFPS * Self.clientReceivedCadenceSevereRatio
        let frameIntervalMs = 1_000.0 / max(1.0, expectedReceiverFPS)
        let receivedWorstGapMs = max(0, snapshot.clientReceivedWorstGapMs)
        let receivedFrameIntervalP95Ms = max(0, snapshot.clientReceivedFrameIntervalP95Ms)
        let receivedFrameIntervalP99Ms = max(0, snapshot.clientReceivedFrameIntervalP99Ms)
        let gapStressThresholdMs = max(
            Self.clientReceivedGapStressMinimumMs,
            frameIntervalMs * Self.clientReceivedGapStressFrameMultiple
        )
        let gapSevereThresholdMs = max(
            Self.clientReceivedGapSevereMinimumMs,
            frameIntervalMs * Self.clientReceivedGapSevereFrameMultiple
        )
        let gapStress = receivedWorstGapMs >= gapStressThresholdMs ||
            receivedFrameIntervalP99Ms >= gapStressThresholdMs ||
            receivedFrameIntervalP95Ms >= gapStressThresholdMs
        let gapSevere = receivedWorstGapMs >= gapSevereThresholdMs ||
            receivedFrameIntervalP99Ms >= gapSevereThresholdMs

        return (
            stress: cadenceStress || gapStress,
            severe: cadenceSevere || gapSevere,
            hostEncodedFPS: hostEncodedFPS,
            receivedFPS: receivedFPS,
            receivedWorstGapMs: receivedWorstGapMs,
            receivedFrameIntervalP95Ms: receivedFrameIntervalP95Ms,
            receivedFrameIntervalP99Ms: receivedFrameIntervalP99Ms
        )
    }

    func isFastStartActive(now: CFAbsoluteTime) -> Bool {
        guard let sessionStartedAt else { return false }
        return now - sessionStartedAt < Self.fastStartDurationSeconds
    }

    func probeCooldown(
        success: Bool,
        now: CFAbsoluteTime,
        qualityRecovery: Bool = false
    ) -> CFAbsoluteTime {
        if promotionRecoveryMode == .conservativeProximity {
            return success
                ? Self.conservativeSuccessfulProbeCooldownSeconds
                : Self.conservativeFailedProbeCooldownSeconds
        }
        if qualityRecovery {
            return success
                ? Self.qualityRecoverySuccessfulProbeCooldownSeconds
                : Self.qualityRecoveryFailedProbeCooldownSeconds
        }

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
