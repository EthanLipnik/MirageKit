//
//  StreamPacketSenderTypes.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/9/26.
//

import CoreGraphics
import CoreMedia
import Foundation
import MirageKit

#if os(macOS)

/// Tracks completion across all packet submissions for one encoded frame.
final class TransportCompletionTracker: @unchecked Sendable {
    /// Mutable completion state protected by `Locked`.
    private struct State {
        var remainingSubmissions = 0
        var didDrop = false
        var firstFailure: (any Error)?
        var isClosed = false
        var didFinish = false
    }

    private let state: Locked<State>
    private let onFinish: @Sendable (_ didDrop: Bool, _ error: (any Error)?, _ completedAt: CFAbsoluteTime) -> Void

    init(
        onFinish: @escaping @Sendable (_ didDrop: Bool, _ error: (any Error)?, _ completedAt: CFAbsoluteTime) -> Void
    ) {
        state = Locked(State())
        self.onFinish = onFinish
    }

    /// Registers one packet submission that must complete before the frame is finished.
    func registerSubmission() {
        state.withLock { $0.remainingSubmissions += 1 }
    }

    /// Records a local drop and finishes once no submissions remain.
    func recordDrop() {
        let finalState = state.withLock { state -> (Bool, (any Error)?)? in
            state.didDrop = true
            return finalizeIfNeeded(state: &state)
        }
        guard let finalState else { return }
        onFinish(finalState.0, finalState.1, CFAbsoluteTimeGetCurrent())
    }

    /// Records transport completion for one packet submission.
    func finishSubmission(error: (any Error)?) {
        let finalState = state.withLock { state -> (Bool, (any Error)?)? in
            if let error, state.firstFailure == nil { state.firstFailure = error }
            guard state.remainingSubmissions > 0 else { return nil }
            state.remainingSubmissions -= 1
            return finalizeIfNeeded(state: &state)
        }
        guard let finalState else { return }
        onFinish(finalState.0, finalState.1, CFAbsoluteTimeGetCurrent())
    }

    /// Closes registration and runs the finish callback after all submissions complete.
    func close() {
        let finalState = state.withLock { state -> (Bool, (any Error)?)? in
            state.isClosed = true
            return finalizeIfNeeded(state: &state)
        }
        guard let finalState else { return }
        onFinish(finalState.0, finalState.1, CFAbsoluteTimeGetCurrent())
    }

    /// Returns final completion state once the tracker is closed and all submissions are done.
    private func finalizeIfNeeded(state: inout State) -> (Bool, (any Error)?)? {
        guard state.isClosed, !state.didFinish, state.remainingSubmissions == 0 else { return nil }
        state.didFinish = true
        return (state.didDrop, state.firstFailure)
    }
}

extension StreamPacketSender {
    nonisolated static let packetPacerBurstWindowMs: Double = 6.0
    nonisolated static let packetPacerSteadyStateBurstWindowMs: Double = 0.5
    nonisolated static let packetPacerSteadyStateFrameBurstFraction: Double = 0.25
    nonisolated static let packetPacerSteadyStateFrameBurstMaxWindowMs: Double = 4.0
    nonisolated static let packetPacerDebtToleranceMs: Double = 1.0
    nonisolated static let packetPacerMaxSleepMsPerPacket: Int = 12
    nonisolated static let packetPacerLogIntervalSeconds: CFAbsoluteTime = 2.0
    nonisolated static let maxQueuedWorkItems: Int = 32
    nonisolated static let maxQueuedBytes: Int = 64 * 1024 * 1024
    nonisolated static let maxReliableQueuedWorkItems: Int = 240
    nonisolated static let maxReliableQueuedBytes: Int = 192 * 1024 * 1024

    nonisolated static func retunedPacketPacerTokens(
        currentTokensBytes: Double,
        oldRateBps: Int,
        newRateBps: Int,
        maxPayloadSize: Int
    ) -> Double {
        guard oldRateBps > 0, newRateBps > 0 else { return 0 }
        let oldBytesPerSecond = Double(oldRateBps) / 8.0
        let newBytesPerSecond = Double(newRateBps) / 8.0
        guard oldBytesPerSecond > 0, newBytesPerSecond > 0 else { return 0 }

        let scaledTokens = currentTokensBytes * newBytesPerSecond / oldBytesPerSecond
        let burstBytes = max(
            Double(max(1, maxPayloadSize)),
            newBytesPerSecond / 1_000.0 * packetPacerSteadyStateFrameBurstMaxWindowMs
        )
        return min(burstBytes, max(-burstBytes, scaledTokens))
    }

    enum DependencyFrameDropReason: String, Sendable {
        case generationAbort = "generation-abort"
        case oversizedFrame = "oversized-frame"
        case queueEviction = "queue-eviction"
        case staleChain = "stale-chain"
    }

    /// Optional pacing override for one frame.
    struct PacingOverride: Equatable {
        let rateBps: Int
        let burstBytes: Int
    }

    /// Encoded frame work item queued for packetization and transport submission.
    struct WorkItem {
        let encodedData: Data
        let frameByteCount: Int
        let isKeyframe: Bool
        let presentationTime: CMTime
        let contentRect: CGRect
        let streamID: StreamID
        let frameNumber: UInt32
        let sequenceNumberStart: UInt32
        let additionalFlags: FrameFlags
        let dimensionToken: UInt16
        let epoch: UInt16
        let fecBlockSize: Int
        let wireBytes: Int
        let logPrefix: String
        let generation: UInt32
        let encodedAt: CFAbsoluteTime
        let sendDeadline: CFAbsoluteTime
        let targetFrameRate: Int
        let pacingOverride: PacingOverride?

        init(
            encodedData: Data,
            frameByteCount: Int,
            isKeyframe: Bool,
            presentationTime: CMTime,
            contentRect: CGRect,
            streamID: StreamID,
            frameNumber: UInt32,
            sequenceNumberStart: UInt32,
            additionalFlags: FrameFlags,
            dimensionToken: UInt16,
            epoch: UInt16,
            fecBlockSize: Int,
            wireBytes: Int,
            logPrefix: String,
            generation: UInt32,
            encodedAt: CFAbsoluteTime,
            sendDeadline: CFAbsoluteTime? = nil,
            targetFrameRate: Int = 60,
            pacingOverride: PacingOverride?
        ) {
            let resolvedTargetFrameRate = max(1, targetFrameRate)
            self.encodedData = encodedData
            self.frameByteCount = frameByteCount
            self.isKeyframe = isKeyframe
            self.presentationTime = presentationTime
            self.contentRect = contentRect
            self.streamID = streamID
            self.frameNumber = frameNumber
            self.sequenceNumberStart = sequenceNumberStart
            self.additionalFlags = additionalFlags
            self.dimensionToken = dimensionToken
            self.epoch = epoch
            self.fecBlockSize = fecBlockSize
            self.wireBytes = wireBytes
            self.logPrefix = logPrefix
            self.generation = generation
            self.encodedAt = encodedAt
            self.targetFrameRate = resolvedTargetFrameRate
            self.sendDeadline = sendDeadline ?? StreamPacketSender.defaultSendDeadline()
            self.pacingOverride = pacingOverride
        }
    }

    /// Snapshot of sender delay, pacing, and drop telemetry for one reporting window.
    struct TelemetrySnapshot {
        let queuedBytes: Int
        let unstartedPFrameCount: Int
        let oldestUnstartedPFrameAgeMs: Double
        let oldestUnstartedPFrameLatenessMs: Double
        let lateReservedPFrameStreak: Int
        let sendStartDelayAverageMs: Double
        let sendStartDelayMaxMs: Double
        let sendCompletionAverageMs: Double
        let sendCompletionMaxMs: Double
        let nonKeyframeSendStartDelayMaxMs: Double
        let nonKeyframeSendCompletionMaxMs: Double
        let packetPacerSleepAverageMs: Double
        let packetPacerSleepTotalMs: Int
        let packetPacerSleepMaxMs: Int
        let packetPacerFrameMaxSleepMs: Int
        let stalePacketDrops: UInt64
        let senderLocalDeadlineDrops: UInt64
        let lateNonKeyframeSends: UInt64
        let generationAbortDrops: UInt64
        let nonKeyframeHoldDrops: UInt64
    }

    /// Current sender freshness state read before host-side encode/reservation.
    struct FreshnessSnapshot: Sendable, Equatable {
        let queuedBytes: Int
        let unstartedPFrameCount: Int
        let oldestUnstartedPFrameAgeMs: Double
        let oldestUnstartedPFrameLatenessMs: Double
        let lateReservedPFrameStreak: Int

        func shouldHoldPFrameReservation(frameRate: Int) -> Bool {
            guard unstartedPFrameCount > 0 else { return false }
            let frameIntervalMs = 1_000.0 / Double(max(1, frameRate))
            return unstartedPFrameCount > 1 ||
                oldestUnstartedPFrameAgeMs > frameIntervalMs * 1.5 ||
                oldestUnstartedPFrameLatenessMs > 0 ||
                lateReservedPFrameStreak > 0
        }
    }

    /// Per-frame transport completion evidence used by host-owned realtime budgeting.
    struct FrameTransportCompletion: Sendable, Equatable {
        let streamID: StreamID
        let frameNumber: UInt32
        let isKeyframe: Bool
        let didSend: Bool
        let frameByteCount: Int
        let wireBytes: Int
        let packetCount: Int
        let dimensionToken: UInt16
        let encodedAt: CFAbsoluteTime
        let startedAt: CFAbsoluteTime
        let completedAt: CFAbsoluteTime

        var sendCompletionMs: Double {
            max(0, (completedAt - encodedAt) * 1000)
        }

        var transportDurationMs: Double {
            max(0, (completedAt - startedAt) * 1000)
        }
    }

    /// Sleep totals accumulated while pacing packet sends.
    struct PacketPacingSleepSample: Equatable {
        let totalMs: Int
        let maxMs: Int
    }

    /// Data and parity fragment counts for one encoded frame.
    struct FragmentPlan: Equatable {
        let dataFragmentCount: Int
        let parityFragmentCount: Int

        /// Total packet count sent for the frame.
        var totalFragmentCount: Int {
            dataFragmentCount + parityFragmentCount
        }
    }

    /// Result from pacing before a packet send.
    struct PacketPacingResult {
        let sleepSample: PacketPacingSleepSample
    }

    /// Queue entry plus its accounted byte cost.
    struct QueuedWorkItem {
        let item: WorkItem
        let accountedBytes: Int
    }

    /// Summary returned after freshness recovery drops queued sender work.
    struct QueueFreshnessResetResult: Equatable {
        let generation: UInt32
        let droppedItemCount: Int
        let droppedNonKeyframeCount: Int
        let droppedKeyframeCount: Int
        let droppedBytes: Int
    }

    /// Shared context passed through data and parity fragment send helpers.
    struct FragmentSendContext {
        let item: WorkItem
        let fragmentPlan: FragmentPlan
        let frameByteCount: Int
        let maxPayload: Int
        let fecBlockSize: Int
        let timestamp: UInt64
        let transportCompletionTracker: TransportCompletionTracker
    }

    /// Mutable progress tracked while sending all fragments for one frame.
    struct FragmentSendProgress {
        var remainingQueuedBytes: Int
        var submittedFragmentCount = 0
        var framePacerSleepTotalMs = 0
        var framePacerSleepMaxMs = 0

        /// Adds pacing sleep from one packet to the frame totals.
        mutating func recordPacingSleep(_ sample: PacketPacingSleepSample) {
            framePacerSleepTotalMs += sample.totalMs
            framePacerSleepMaxMs = max(framePacerSleepMaxMs, sample.maxMs)
        }
    }

    /// Outcome from trying to send one data or parity fragment.
    enum FragmentSendOutcome {
        case skipped
        case submitted(accountedPayloadBytes: Int, sleepSample: PacketPacingSleepSample)
        case stopped
    }

    /// Queue admission result from locked enqueue processing.
    enum QueueAdmissionResult {
        case enqueued(queuedBytes: Int)
        case dropped
    }

    /// Returns the packet pacing sleep needed to stay within the token budget.
    nonisolated static func packetPacerSleepMilliseconds(
        tokensBeforeSend: Double,
        packetBytes: Int,
        bytesPerMillisecond: Double,
        debtToleranceMs: Double = packetPacerDebtToleranceMs,
        maxSleepMs: Int = packetPacerMaxSleepMsPerPacket
    ) -> Int {
        guard packetBytes > 0, bytesPerMillisecond > 0, maxSleepMs > 0 else { return 0 }
        let toleranceBytes = bytesPerMillisecond * max(0.0, debtToleranceMs)
        let projectedTokens = tokensBeforeSend - Double(packetBytes)
        let projectedDebtBytes = max(0.0, -projectedTokens - toleranceBytes)
        guard projectedDebtBytes > 0 else { return 0 }
        let rawSleep = Int(ceil(projectedDebtBytes / bytesPerMillisecond))
        return max(1, min(maxSleepMs, rawSleep))
    }

    /// Returns the burst window for keyframe or steady-state packet pacing.
    nonisolated static func packetPacerBurstWindowMilliseconds(
        isKeyframeBurst: Bool,
        totalFragments: Int,
        targetFrameIntervalMs: Double? = nil
    ) -> Double {
        guard isKeyframeBurst else {
            guard let targetFrameIntervalMs, targetFrameIntervalMs > 0 else {
                return packetPacerSteadyStateBurstWindowMs
            }
            let frameScaledWindowMs = targetFrameIntervalMs * packetPacerSteadyStateFrameBurstFraction
            return min(
                packetPacerSteadyStateFrameBurstMaxWindowMs,
                max(packetPacerSteadyStateBurstWindowMs, frameScaledWindowMs)
            )
        }
        guard totalFragments > 0 else { return packetPacerBurstWindowMs }
        return packetPacerBurstWindowMs
    }

    /// Returns token bucket parameters for packet pacing.
    nonisolated static func packetPacingParameters(
        targetRateBps: Int,
        packetBytes: Int,
        isKeyframeBurst: Bool,
        totalFragments: Int,
        targetFrameIntervalMs: Double? = nil,
        pacingOverride: PacingOverride?
    ) -> (bytesPerSecond: Double, burstBytes: Double)? {
        guard packetBytes > 0 else { return nil }

        let overrideRate = max(0, pacingOverride?.rateBps ?? 0)
        let effectiveRateBps = overrideRate > 0 ? overrideRate : targetRateBps
        guard effectiveRateBps > 0 else { return nil }

        let bytesPerSecond = max(1.0, Double(effectiveRateBps) / 8.0)
        let bytesPerMillisecond = max(1.0, bytesPerSecond / 1000.0)
        let burstWindowMs = packetPacerBurstWindowMilliseconds(
            isKeyframeBurst: isKeyframeBurst,
            totalFragments: totalFragments,
            targetFrameIntervalMs: targetFrameIntervalMs
        )
        let computedBurstBytes = max(
            bytesPerMillisecond,
            bytesPerMillisecond * burstWindowMs
        )
        let burstBytes = if let pacingOverride {
            min(computedBurstBytes, Double(max(packetBytes, pacingOverride.burstBytes)))
        } else {
            computedBurstBytes
        }

        return (bytesPerSecond, burstBytes)
    }

    /// Default send deadline for keyframes and dependent non-keyframes.
    nonisolated static func defaultSendDeadline() -> CFAbsoluteTime {
        .greatestFiniteMagnitude
    }

    /// Returns whether the sender should duplicate the parameter-set packet.
    nonisolated static func shouldDuplicateParameterSetPacket(
        isEnabled: Bool,
        isKeyframe: Bool,
        fragmentIndex: Int,
        flags: FrameFlags
    ) -> Bool {
        guard isEnabled else { return false }
        guard isKeyframe else { return false }
        guard fragmentIndex == 0 else { return false }
        return flags.contains(.parameterSet)
    }

    /// Builds a fragment plan that keeps header counts representable.
    nonisolated static func fragmentPlan(
        frameByteCount: Int,
        maxPayload: Int,
        fecBlockSize: Int
    ) -> FragmentPlan {
        let maxPayload = max(0, maxPayload)
        let frameByteCount = max(0, frameByteCount)
        let dataFragmentCount = if frameByteCount > 0, maxPayload > 0 {
            (frameByteCount + maxPayload - 1) / maxPayload
        } else {
            0
        }
        let blockSize = max(0, fecBlockSize)
        let parityFragmentCount = if dataFragmentCount > 0, blockSize > 1 {
            (dataFragmentCount + blockSize - 1) / blockSize
        } else {
            0
        }
        return FragmentPlan(
            dataFragmentCount: dataFragmentCount,
            parityFragmentCount: parityFragmentCount
        )
    }

    /// Returns wire send order for data and FEC parity fragments.
    nonisolated static func fragmentSendOrder(
        dataFragmentCount: Int,
        parityFragmentCount: Int,
        fecBlockSize: Int
    ) -> [Int] {
        let dataFragmentCount = max(0, dataFragmentCount)
        let parityFragmentCount = max(0, parityFragmentCount)
        guard dataFragmentCount > 0 else { return [] }
        guard parityFragmentCount > 0, fecBlockSize > 1 else {
            return Array(0 ..< dataFragmentCount + parityFragmentCount)
        }

        var order: [Int] = []
        order.reserveCapacity(dataFragmentCount + parityFragmentCount)
        for parityIndex in 0 ..< parityFragmentCount {
            let blockStart = parityIndex * fecBlockSize
            let blockEnd = min(blockStart + fecBlockSize, dataFragmentCount)
            guard blockStart < blockEnd else { break }
            order.append(contentsOf: blockStart ..< blockEnd)
            order.append(dataFragmentCount + parityIndex)
        }
        return order
    }

    nonisolated static func canRepresentFragmentPlan(
        _ fragmentPlan: FragmentPlan,
        frameByteCount: Int
    ) -> Bool {
        frameByteCount >= 0 &&
            frameByteCount <= Int(UInt32.max) &&
            fragmentPlan.totalFragmentCount <= Int(UInt16.max)
    }
}

#endif
