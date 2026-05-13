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
    let deliveryRatio: Double
    let deliveryStress: Bool
    let deliverySevere: Bool
    let hostEncodedFPS: Double
    let receivedFPS: Double
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
                isTransportClean: false,
                allowsProbePromotion: false,
                suppressesProbePromotion: true,
                transportPressureReason: nil
            )
        }

        let requestedTargetFrameRate = max(1, snapshot.hostTargetFrameRate > 0 ? snapshot.hostTargetFrameRate : 60)
        let targetFPS = Double(
            effectiveHealthFrameRate(
                requestedTargetFrameRate: requestedTargetFrameRate,
                minimumHealthyFrameRate: minimumHealthyFrameRate
            )
        )
        let queueBytes = max(0, snapshot.hostSendQueueBytes ?? 0)
        let sendStartDelayAverageMs = max(0, snapshot.hostSendStartDelayAverageMs ?? 0)
        let sendCompletionAverageMs = max(0, snapshot.hostSendCompletionAverageMs ?? 0)
        let packetPacerAverageSleepMs = max(0, snapshot.hostPacketPacerAverageSleepMs ?? 0)
        let transportDropCount = (snapshot.hostStalePacketDrops ?? 0) +
            (snapshot.hostSenderLocalDeadlineDrops ?? 0)

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

        let hostPipelineHealthy = Self.hostPipelineHealthy(snapshot: snapshot, targetFPS: targetFPS)
        let clientCanVerifyTransport = Self.clientCanVerifyTransport(snapshot: snapshot, targetFPS: targetFPS)
        let deliveryRatio = snapshot.hostEncodedFPS > 0
            ? max(0, snapshot.receivedFPS) / max(1, snapshot.hostEncodedFPS)
            : 1
        let deliveryBelowHealthFloor = max(0, snapshot.receivedFPS) < targetFPS * Self.deliveryStressRatio
        let deliverySevereBelowHealthFloor = max(0, snapshot.receivedFPS) < targetFPS * Self.deliverySevereRatio
        let deliveryStress = hostPipelineHealthy &&
            clientCanVerifyTransport &&
            deliveryBelowHealthFloor &&
            deliveryRatio < Self.deliveryStressRatio
        let deliverySevere = hostPipelineHealthy &&
            clientCanVerifyTransport &&
            deliverySevereBelowHealthFloor &&
            deliveryRatio < Self.deliverySevereRatio
        let clientKeyframeStarved = hostPipelineHealthy &&
            snapshot.clientReassemblerPendingKeyframeCount > 0
        let clientStarvationStress = clientKeyframeStarved && (
            snapshot.receivedFPS < targetFPS * Self.clientStarvationStressRatio ||
                snapshot.decodedFPS < targetFPS * Self.clientStarvationStressRatio ||
                snapshot.submittedFPS < targetFPS * Self.clientStarvationStressRatio ||
                snapshot.clientDroppedFrames > 0 ||
                !snapshot.decodeHealthy
        )

        let pairedPacerStress = pacerStress && (queueStress || dropStress)
        let pairedPacerSevere = pacerSevere && (queueSevere || dropSevere)
        let severeTransportPressure = queueSevere ||
            sendDelaySevere ||
            dropSevere ||
            pairedPacerSevere ||
            deliverySevere
        let sustainedTransportPressure = queueStress ||
            sendDelaySevere ||
            dropStress ||
            pairedPacerStress ||
            deliveryStress
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
                deliveryRatio: deliveryRatio,
                deliveryStress: deliveryStress,
                deliverySevere: deliverySevere,
                hostEncodedFPS: snapshot.hostEncodedFPS,
                receivedFPS: snapshot.receivedFPS
            )
        )

        let targetFrameIntervalMs = 1000.0 / targetFPS
        let smoothEnoughForPromotion = snapshot.clientPresentationStallCount == 0 &&
            snapshot.clientWorstPresentationGapMs < max(250, targetFrameIntervalMs * 4) &&
            (
                snapshot.clientFrameIntervalP99Ms == 0 ||
                    snapshot.clientFrameIntervalP99Ms < max(120, targetFrameIntervalMs * 3)
            ) &&
            (
                snapshot.clientDisplayTickIntervalP99Ms == 0 ||
                    snapshot.clientDisplayTickIntervalP99Ms < max(120, targetFrameIntervalMs * 3)
            ) &&
            snapshot.clientPendingFrameAgeMs < max(80, targetFrameIntervalMs * 5)
        let suppressesProbePromotion = queueBytes > 0 ||
            transportDropCount > 0 ||
            sendDelayStress ||
            pacerStress ||
            clientStarvationStress
        let bottleneckKind = snapshot.bottleneckKind
        let clientBottleneckBlocksPromotion =
            bottleneckKind == .decodeBound ||
            bottleneckKind == .presentationBound ||
            !snapshot.decodeHealthy

        return ReceiverHealthSample(
            hasSevereTransportPressure: severeTransportPressure,
            hasTransportPressure: severeTransportPressure || sustainedTransportPressure,
            isTransportClean: !severeTransportPressure && !sustainedTransportPressure,
            allowsProbePromotion: !suppressesProbePromotion &&
                !clientBottleneckBlocksPromotion &&
                smoothEnoughForPromotion,
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
        if context.sendDelaySevere || context.sendDelayStress {
            let startText = Self.formatMilliseconds(context.sendStartDelayAverageMs)
            let completionText = Self.formatMilliseconds(context.sendCompletionAverageMs)
            return "host send delay start=\(startText) completion=\(completionText)"
        }
        if context.pairedPacerSevere || context.pairedPacerStress {
            return "packet pacer \(formatMilliseconds(context.packetPacerAverageSleepMs)) with queue/drop pressure"
        }
        if context.deliverySevere || context.deliveryStress {
            let ratio = Int((context.deliveryRatio * 100).rounded())
            let encodedText = context.hostEncodedFPS.formatted(.number.precision(.fractionLength(1)))
            let receivedText = context.receivedFPS.formatted(.number.precision(.fractionLength(1)))
            return "delivery collapse \(ratio)% received (host=\(encodedText)fps received=\(receivedText)fps)"
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

    private static func hostPipelineHealthy(
        snapshot: MirageClientMetricsSnapshot,
        targetFPS: Double
    ) -> Bool {
        let captureFPS = max(
            snapshot.hostCaptureIngressFPS ?? 0,
            snapshot.hostCaptureFPS ?? 0,
            snapshot.hostEncodeAttemptFPS ?? 0
        )
        let encodedFPS = max(0, snapshot.hostEncodedFPS)
        return captureFPS >= targetFPS * 0.85 &&
            encodedFPS >= targetFPS * 0.75 &&
            snapshot.bottleneckKind != .captureBound &&
            snapshot.bottleneckKind != .encodeBound &&
            snapshot.bottleneckKind != .hostCadenceLimited
    }

    private static func clientCanVerifyTransport(
        snapshot: MirageClientMetricsSnapshot,
        targetFPS: Double
    ) -> Bool {
        guard snapshot.decodeHealthy else { return false }
        if snapshot.bottleneckKind == .decodeBound ||
            snapshot.bottleneckKind == .presentationBound {
            return false
        }
        let targetFrameIntervalMs = 1000.0 / targetFPS
        return snapshot.clientPresentationStallCount == 0 &&
            snapshot.clientWorstPresentationGapMs < max(250, targetFrameIntervalMs * 6)
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
