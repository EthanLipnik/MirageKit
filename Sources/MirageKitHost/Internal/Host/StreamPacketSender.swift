//
//  StreamPacketSender.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/15/26.
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
import Foundation

#if os(macOS)

/// Queues, paces, fragments, and submits encoded video frames to the host media transport.
actor StreamPacketSender {
    let maxPayloadSize: Int
    let mediaSecurityKey: MirageMediaPacketKey?
    let sendPacket: PacketMetadataSendHandler
    let queuedUnreliableDiagnosticsProvider:
        (@Sendable (MirageMedia.MirageMediaSendProfile) async -> MirageQueuedUnreliableSendDiagnostics?)?
    let onSendError: (@Sendable (Error) -> Void)?
    let duplicatesParameterSetPackets: Bool
    nonisolated let onDependencyFrameDropped:
        (@Sendable (_ streamID: StreamID, _ frameNumber: UInt32, _ reason: DependencyFrameDropReason) -> Void)?
    nonisolated let onFrameTransportCompleted:
        (@Sendable (_ completion: FrameTransportCompletion) -> Void)?
    let packetBufferPool: PacketBufferPool
    private var sendTask: Task<Void, Never>?
    /// Accessed from encoder callbacks; lifecycle is managed by start/stop.
    private nonisolated(unsafe) var sendContinuation: AsyncStream<Void>.Continuation?
    // Snapshot read from encoder callbacks to tag enqueued frames.
    nonisolated(unsafe) var generation: UInt32 = 0
    nonisolated(unsafe) var queuedWorkItems: [QueuedWorkItem] = []
    nonisolated(unsafe) var queuedBytes: Int = 0
    nonisolated(unsafe) var dropNonKeyframesUntilKeyframe: Bool = false
    nonisolated(unsafe) var dependencyRecoveryRequiresKeyframe: Bool = false
    nonisolated(unsafe) var latestKeyframeFrameNumber: UInt32 = 0
    nonisolated(unsafe) var latestKeyframeGeneration: UInt32 = 0
    nonisolated(unsafe) var latestDependencyDropFrameNumber: UInt32 = 0
    nonisolated(unsafe) var latestDependencyDropGeneration: UInt32 = 0
    nonisolated(unsafe) var dependencyBaselineKeyframeFrameNumber: UInt32 = 0
    nonisolated(unsafe) var dependencyBaselineKeyframeGeneration: UInt32 = 0
    nonisolated(unsafe) var queuedStalePacketDropCount: UInt64 = 0
    nonisolated(unsafe) var queuedSenderLocalDeadlineDropCount: UInt64 = 0
    nonisolated(unsafe) var queuedGenerationAbortDropCount: UInt64 = 0
    nonisolated(unsafe) var queuedNonKeyframeHoldDropCount: UInt64 = 0
    nonisolated(unsafe) var lateReservedPFrameStreak: Int = 0
    let queueLock = NSLock()

    var pacerRateBps: Int = 0
    var pacerTokensBytes: Double = 0
    var pacerLastRefillTime: CFAbsoluteTime = 0
    var pacerSleepTotalMs: Int = 0
    var pacerSleepMaxMs: Int = 0
    var pacerFrameSleepMaxMs: Int = 0
    var pacerSleepPacketCount: Int = 0
    var pacerLastLogTime: CFAbsoluteTime = 0
    var awdlPressurePacingDeadline: CFAbsoluteTime = 0
    var awdlPressurePacingReason: String?
    var sendStartDelayTotalMs: Double = 0
    var sendStartDelayMaxMs: Double = 0
    var sendStartDelayCount: UInt64 = 0
    var sendCompletionTotalMs: Double = 0
    var sendCompletionMaxMs: Double = 0
    var sendCompletionCount: UInt64 = 0
    var nonKeyframeSendStartDelayMaxMs: Double = 0
    var nonKeyframeSendCompletionMaxMs: Double = 0
    var stalePacketDropCount: UInt64 = 0
    var lateNonKeyframeSendCount: UInt64 = 0
    var generationAbortDropCount: UInt64 = 0
    var nonKeyframeHoldDropCount: UInt64 = 0
    var queuedUnreliableDropCounts = QueuedUnreliableDropCounts()

    init(
        maxPayloadSize: Int,
        mediaSecurityContext: MirageMediaSecurityContext? = nil,
        sendPacketWithMetadata: @escaping PacketMetadataSendHandler,
        queuedUnreliableDiagnosticsProvider:
        (@Sendable (MirageMedia.MirageMediaSendProfile) async -> MirageQueuedUnreliableSendDiagnostics?)? = nil,
        onSendError: (@Sendable (Error) -> Void)? = nil,
        duplicatesParameterSetPackets: Bool = false,
        onDependencyFrameDropped:
        (@Sendable (_ streamID: StreamID, _ frameNumber: UInt32, _ reason: DependencyFrameDropReason) -> Void)? = nil,
        onFrameTransportCompleted:
        (@Sendable (_ completion: FrameTransportCompletion) -> Void)? = nil
    ) {
        self.maxPayloadSize = maxPayloadSize
        mediaSecurityKey = mediaSecurityContext.map(MirageMediaPacketKey.init(context:))
        sendPacket = sendPacketWithMetadata
        self.queuedUnreliableDiagnosticsProvider = queuedUnreliableDiagnosticsProvider
        self.onSendError = onSendError
        self.duplicatesParameterSetPackets = duplicatesParameterSetPackets
        self.onDependencyFrameDropped = onDependencyFrameDropped
        self.onFrameTransportCompleted = onFrameTransportCompleted
        packetBufferPool = PacketBufferPool(
            capacity: MirageWire.mirageHeaderSize + maxPayloadSize + MirageMediaSecurity.authTagLength
        )
    }
}

// MARK: - Lifecycle

extension StreamPacketSender {
    /// Starts the send loop and clears any stale queued work.
    func start() {
        guard sendTask == nil else { return }
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        sendContinuation = continuation
        queueLock.withLock {
            resetQueueStorageLocked()
        }
        resetPacketPacerState(now: CFAbsoluteTimeGetCurrent())
        awdlPressurePacingDeadline = 0
        awdlPressurePacingReason = nil
        resetTelemetryWindow()
        sendTask = Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            for await _ in stream {
                while let item = dequeueNextWorkItem() {
                    await handle(item)
                }
            }
        }
    }

    /// Stops the send loop and drops all queued work.
    func stop() async {
        sendContinuation?.finish()
        sendContinuation = nil
        sendTask?.cancel()
        sendTask = nil
        queueLock.withLock {
            resetQueueStorageLocked()
        }
        resetPacketPacerState(now: CFAbsoluteTimeGetCurrent())
        awdlPressurePacingDeadline = 0
        awdlPressurePacingReason = nil
        resetTelemetryWindow()
    }

    /// Updates the pacing target used for outgoing packets.
    func setTargetBitrateBps(_ bitrate: Int?) {
        let sanitized = max(0, bitrate ?? 0)
        guard sanitized != pacerRateBps else { return }
        let oldRate = pacerRateBps
        let oldTokens = pacerTokensBytes
        pacerRateBps = sanitized
        pacerTokensBytes = Self.retunedPacketPacerTokens(
            currentTokensBytes: oldTokens,
            oldRateBps: oldRate,
            newRateBps: sanitized,
            maxPayloadSize: maxPayloadSize
        )
        pacerLastRefillTime = CFAbsoluteTimeGetCurrent()
    }

    /// Advances the sender generation so already queued or in-flight work becomes stale.
    func bumpGeneration(reason: String) async {
        generation &+= 1
        queueLock.withLock {
            resetDependencyTrackingLocked()
        }
        MirageLogger.stream("Packet send generation bumped to \(generation) (\(reason))")
    }

    /// Drops all queued work and advances the generation.
    func resetQueue(reason: String) async {
        generation &+= 1
        queueLock.withLock {
            resetQueueStorageLocked()
        }
        resetPacketPacerState(now: CFAbsoluteTimeGetCurrent())
        MirageLogger.stream("Packet send queue reset (gen \(generation), \(reason))")
    }

    /// Drops queued sender work and advances generation for a freshness recovery transaction.
    func resetQueueForFreshnessRecovery(reason: String) async -> QueueFreshnessResetResult {
        generation &+= 1
        let currentGeneration = generation
        let result = queueLock.withLock {
            let droppedItemCount = queuedWorkItems.count
            let droppedNonKeyframeCount = queuedWorkItems.filter { !$0.item.isKeyframe }.count
            let droppedKeyframeCount = droppedItemCount - droppedNonKeyframeCount
            let droppedBytes = queuedBytes
            resetQueueStorageLocked()
            return QueueFreshnessResetResult(
                generation: currentGeneration,
                droppedItemCount: droppedItemCount,
                droppedNonKeyframeCount: droppedNonKeyframeCount,
                droppedKeyframeCount: droppedKeyframeCount,
                droppedBytes: droppedBytes
            )
        }
        resetPacketPacerState(now: CFAbsoluteTimeGetCurrent())
        MirageLogger.stream(
            "Packet send queue freshness reset (gen \(currentGeneration), \(reason), " +
                "items=\(result.droppedItemCount), bytes=\(result.droppedBytes))"
        )
        return result
    }

    /// Holds AWDL media pacing in a low-burst profile while receiver feedback indicates burst sensitivity.
    func activateAwdlPressurePacing(until deadline: CFAbsoluteTime, reason: String) {
        let now = CFAbsoluteTimeGetCurrent()
        guard deadline > now else { return }

        let wasInactive = awdlPressurePacingDeadline <= now
        let shouldLog = wasInactive || awdlPressurePacingReason != reason
        awdlPressurePacingDeadline = max(awdlPressurePacingDeadline, deadline)
        awdlPressurePacingReason = reason
        if wasInactive {
            resetPacketPacerState(now: now)
        }

        guard shouldLog else { return }
        let holdMs = Int(max(0, awdlPressurePacingDeadline - now) * 1000)
        MirageLogger.network(
            "AWDL pressure pacing active for stream sender: reason=\(reason), hold=\(holdMs)ms"
        )
    }

    /// Current queued byte count used by tests and telemetry.
    nonisolated var queuedByteCount: Int {
        queueLock.withLock { queuedBytes }
    }

    /// Current generation tagged onto newly enqueued work.
    nonisolated var currentGeneration: UInt32 {
        generation
    }

    /// Enqueues encoded frame work from encoder callbacks.
    nonisolated func enqueue(_ item: WorkItem) {
        let accountedBytes = accountedWireBytes(for: item)
        let admission = queueLock.withLock {
            enqueueLocked(
                item,
                accountedBytes: accountedBytes
            )
        }
        guard case .enqueued = admission else { return }
        sendContinuation?.yield(())
    }

    /// Applies queue admission, keyframe supersession, and realtime queue bounds while locked.
    private nonisolated func enqueueLocked(
        _ item: WorkItem,
        accountedBytes: Int
    )
    -> QueueAdmissionResult {
        guard sendContinuation != nil else { return .dropped }
        guard item.generation == generation else {
            queuedGenerationAbortDropCount &+= 1
            return .dropped
        }

        if item.isKeyframe {
            recordDependencyBaselineKeyframeLocked(item)
            if latestKeyframeGeneration != item.generation || item.frameNumber >= latestKeyframeFrameNumber {
                dropNonKeyframesUntilKeyframe = true
                latestKeyframeFrameNumber = item.frameNumber
                latestKeyframeGeneration = item.generation
            }
            discardQueuedNonKeyframesLocked(countAsHoldDrops: true)
            discardSupersededQueuedKeyframesLocked(newestFrameNumber: item.frameNumber, generation: item.generation)
        } else if dropNonKeyframesUntilKeyframe, !dependencyRecoveryRequiresKeyframe,
                  latestKeyframeGeneration == item.generation,
                  !hasQueuedKeyframeLocked(frameNumber: latestKeyframeFrameNumber, generation: latestKeyframeGeneration) {
            resetKeyframeTrackingLocked()
        }

        queuedWorkItems.append(QueuedWorkItem(item: item, accountedBytes: accountedBytes))
        queuedBytes += accountedBytes

        if item.usesAwdlRealtimeQueuePolicy {
            enforceAwdlRealtimeQueueBoundsLocked()
        } else if !item.isKeyframe {
            enforceRealtimeQueueBoundsLocked()
        }

        return .enqueued(queuedBytes: queuedBytes)
    }

    /// Removes the next queued work item for the send loop.
    private nonisolated func dequeueNextWorkItem() -> WorkItem? {
        queueLock.withLock {
            guard !queuedWorkItems.isEmpty else { return nil }
            return queuedWorkItems.removeFirst().item
        }
    }

    /// Sends one queued frame or drops it if generation/dependency state made it stale.
    private func handle(_ item: WorkItem) async {
        let accountedBytes = accountedWireBytes(for: item)
        let currentGeneration = generation
        let (shouldDropNonKeyframes, newestKeyframe, newestKeyframeGeneration) = queueLock.withLock {
            (dropNonKeyframesUntilKeyframe, latestKeyframeFrameNumber, latestKeyframeGeneration)
        }
        guard item.generation == currentGeneration else {
            generationAbortDropCount &+= 1
            if item.isKeyframe {
                MirageLogger
                    .stream("Dropping stale keyframe \(item.frameNumber) (gen \(item.generation) != \(currentGeneration))")
                queueLock.withLock {
                    if latestKeyframeGeneration == item.generation, latestKeyframeFrameNumber == item.frameNumber {
                        resetKeyframeTrackingLocked()
                    }
                }
            }
            reduceQueuedBytes(accountedBytes)
            return
        }
        let sendStartTime = CFAbsoluteTimeGetCurrent()
        let latenessMs = nonKeyframeDeadlineLatenessMs(item, now: sendStartTime)
        if shouldAbandonReservedPFrameForFreshness(item, latenessMs: latenessMs) {
            queuedSenderLocalDeadlineDropCount &+= 1
            stalePacketDropCount &+= 1
            reduceQueuedBytes(accountedBytes)
            queueLock.withLock {
                markDependencyFrameDroppedLocked(
                    item,
                    reason: .staleChain
                )
            }
            let roundedLatenessMs = ((latenessMs ?? 0) * 10).rounded() / 10
            MirageLogger.stream(
                "event=reserved_p_frame_stale_chain frame=\(item.frameNumber) stream=\(item.streamID) " +
                    "latenessMs=\(roundedLatenessMs) streak=\(lateReservedPFrameStreak) " +
                    "wireBytes=\(item.wireBytes)"
            )
            return
        }
        recordReservedPFrameLatenessIfNeeded(item, now: sendStartTime)
        if item.isKeyframe, newestKeyframeGeneration == currentGeneration,
           newestKeyframe > 0, item.frameNumber < newestKeyframe {
            stalePacketDropCount &+= 1
            reduceQueuedBytes(accountedBytes)
            MirageLogger.stream("Dropping stale keyframe \(item.frameNumber) (newest \(newestKeyframe))")
            return
        }
        if shouldDropNonKeyframes, newestKeyframeGeneration == currentGeneration, !item.isKeyframe {
            nonKeyframeHoldDropCount &+= 1
            reduceQueuedBytes(accountedBytes)
            return
        }

        if item.isKeyframe {
            queueLock.withLock {
                recordDependencyBaselineKeyframeLocked(item)
                if latestKeyframeGeneration == item.generation,
                   latestKeyframeFrameNumber == item.frameNumber,
                   keyframeSatisfiesDependencyRecoveryLocked(item) {
                    resetKeyframeTrackingLocked()
                }
            }
        }
        await fragmentAndSendPackets(item, accountedBytes: accountedBytes)
    }
}

#endif
