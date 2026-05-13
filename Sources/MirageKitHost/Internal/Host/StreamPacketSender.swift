//
//  StreamPacketSender.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/15/26.
//

import Foundation
import MirageKit

#if os(macOS)

/// Queues, paces, fragments, and submits encoded video frames to the host media transport.
actor StreamPacketSender {
    let maxPayloadSize: Int
    let mediaSecurityKey: MirageMediaPacketKey?
    let sendPacket: @Sendable (Data, @escaping @Sendable (Error?) -> Void) -> Void
    let onSendError: (@Sendable (Error) -> Void)?
    nonisolated let onDependencyFrameDropped:
        (@Sendable (_ streamID: StreamID, _ frameNumber: UInt32, _ reason: DependencyFrameDropReason) -> Void)?
    let packetBufferPool: PacketBufferPool
    static let awdlExperimentEnabledFromEnvironment = MirageEnvironmentValue.isTruthy(
        ProcessInfo.processInfo.environment["MIRAGE_AWDL_EXPERIMENT"]
    )
    let awdlExperimentEnabled = StreamPacketSender.awdlExperimentEnabledFromEnvironment
    private var sendTask: Task<Void, Never>?
    /// Accessed from encoder callbacks; lifecycle is managed by start/stop.
    private nonisolated(unsafe) var sendContinuation: AsyncStream<Void>.Continuation?
    // Snapshot read from encoder callbacks to tag enqueued frames.
    nonisolated(unsafe) var generation: UInt32 = 0
    nonisolated(unsafe) var queuedWorkItems: [QueuedWorkItem] = []
    nonisolated(unsafe) var queuedBytes: Int = 0
    nonisolated(unsafe) var dropNonKeyframesUntilKeyframe: Bool = false
    nonisolated(unsafe) var latestKeyframeFrameNumber: UInt32 = 0
    nonisolated(unsafe) var latestKeyframeGeneration: UInt32 = 0
    nonisolated(unsafe) var dependencyDropSuppressionDeadline: CFAbsoluteTime = 0
    nonisolated(unsafe) var queuedStalePacketDropCount: UInt64 = 0
    nonisolated(unsafe) var queuedSenderLocalDeadlineDropCount: UInt64 = 0
    nonisolated(unsafe) var queuedGenerationAbortDropCount: UInt64 = 0
    nonisolated(unsafe) var queuedNonKeyframeHoldDropCount: UInt64 = 0
    let queueLock = NSLock()

    var pacerRateBps: Int = 0
    var pacerTokensBytes: Double = 0
    var pacerLastRefillTime: CFAbsoluteTime = 0
    var pacerSleepTotalMs: Int = 0
    var pacerSleepMaxMs: Int = 0
    var pacerFrameSleepMaxMs: Int = 0
    var pacerSleepPacketCount: Int = 0
    var pacerLastLogTime: CFAbsoluteTime = 0
    var sendStartDelayTotalMs: Double = 0
    var sendStartDelayMaxMs: Double = 0
    var sendStartDelayCount: UInt64 = 0
    var sendCompletionTotalMs: Double = 0
    var sendCompletionMaxMs: Double = 0
    var sendCompletionCount: UInt64 = 0
    var nonKeyframeSendStartDelayMaxMs: Double = 0
    var nonKeyframeSendCompletionMaxMs: Double = 0
    var stalePacketDropCount: UInt64 = 0
    var generationAbortDropCount: UInt64 = 0
    var nonKeyframeHoldDropCount: UInt64 = 0

    init(
        maxPayloadSize: Int,
        mediaSecurityContext: MirageMediaSecurityContext? = nil,
        sendPacket: @escaping @Sendable (Data, @escaping @Sendable (Error?) -> Void) -> Void,
        onSendError: (@Sendable (Error) -> Void)? = nil,
        onDependencyFrameDropped:
        (@Sendable (_ streamID: StreamID, _ frameNumber: UInt32, _ reason: DependencyFrameDropReason) -> Void)? = nil
    ) {
        self.maxPayloadSize = maxPayloadSize
        mediaSecurityKey = mediaSecurityContext.map(MirageMediaPacketKey.init(context:))
        self.sendPacket = sendPacket
        self.onSendError = onSendError
        self.onDependencyFrameDropped = onDependencyFrameDropped
        packetBufferPool = PacketBufferPool(
            capacity: mirageHeaderSize + maxPayloadSize + MirageMediaSecurity.authTagLength
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
        resetTelemetryWindow()
    }

    /// Updates the pacing target used for outgoing packets.
    func setTargetBitrateBps(_ bitrate: Int?) {
        let sanitized = max(0, bitrate ?? 0)
        guard sanitized != pacerRateBps else { return }
        pacerRateBps = sanitized
        resetPacketPacerState(now: CFAbsoluteTimeGetCurrent())
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
        let now = CFAbsoluteTimeGetCurrent()
        let admission = queueLock.withLock {
            enqueueLocked(
                item,
                accountedBytes: accountedBytes,
                now: now
            )
        }
        guard case .enqueued = admission else { return }
        sendContinuation?.yield(())
    }

    /// Applies queue admission, keyframe supersession, and realtime queue bounds while locked.
    private nonisolated func enqueueLocked(
        _ item: WorkItem,
        accountedBytes: Int,
        now: CFAbsoluteTime
    )
    -> QueueAdmissionResult {
        guard sendContinuation != nil else { return .dropped }
        discardExpiredQueuedNonKeyframesLocked(now: now)

        guard item.generation == generation else {
            queuedGenerationAbortDropCount &+= 1
            return .dropped
        }

        if isExpiredNonKeyframe(item, now: now) {
            queuedStalePacketDropCount &+= 1
            markDependencyFrameDroppedLocked(item, reason: .expiredBeforeEnqueue, clientVisible: false)
            return .dropped
        }

        if item.isKeyframe {
            extendDependencyDropSuppressionLocked(now: now)
            if latestKeyframeGeneration != item.generation || item.frameNumber >= latestKeyframeFrameNumber {
                dropNonKeyframesUntilKeyframe = true
                latestKeyframeFrameNumber = item.frameNumber
                latestKeyframeGeneration = item.generation
            }
            discardQueuedNonKeyframesLocked(countAsHoldDrops: true)
            discardSupersededQueuedKeyframesLocked(newestFrameNumber: item.frameNumber, generation: item.generation)
        } else if dropNonKeyframesUntilKeyframe, latestKeyframeGeneration == item.generation,
                  !hasQueuedKeyframeLocked(frameNumber: latestKeyframeFrameNumber, generation: latestKeyframeGeneration) {
            resetKeyframeTrackingLocked()
        }

        queuedWorkItems.append(QueuedWorkItem(item: item, accountedBytes: accountedBytes))
        queuedBytes += accountedBytes

        if !item.isKeyframe {
            enforceRealtimeQueueBoundsLocked(now: now)
        }

        return .enqueued(queuedBytes: queuedBytes)
    }

    /// Removes the next non-expired work item for the send loop.
    private nonisolated func dequeueNextWorkItem() -> WorkItem? {
        queueLock.withLock {
            discardExpiredQueuedNonKeyframesLocked(now: CFAbsoluteTimeGetCurrent())
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
        if isExpiredNonKeyframe(item, now: CFAbsoluteTimeGetCurrent()) {
            stalePacketDropCount &+= 1
            queueLock.withLock {
                markDependencyFrameDroppedLocked(item, reason: .expiredBeforeSend, clientVisible: false)
            }
            reduceQueuedBytes(accountedBytes)
            return
        }
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
                extendDependencyDropSuppressionLocked(now: CFAbsoluteTimeGetCurrent())
                if latestKeyframeGeneration == item.generation, latestKeyframeFrameNumber == item.frameNumber {
                    resetKeyframeTrackingLocked()
                }
            }
        }
        await fragmentAndSendPackets(item, accountedBytes: accountedBytes)
    }
}

#endif
