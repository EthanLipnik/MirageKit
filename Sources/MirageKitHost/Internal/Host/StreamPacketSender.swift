//
//  StreamPacketSender.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/15/26.
//

import CoreGraphics
import CoreMedia
import Foundation
import MirageKit

#if os(macOS)

actor StreamPacketSender {
    struct PacingOverride: Sendable, Equatable {
        let rateBps: Int
        let burstBytes: Int
    }

    struct WorkItem: Sendable {
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
        let pacingOverride: PacingOverride?
    }

    struct PacketBudgetSnapshot: Sendable {
        let targetBitrateBps: Int
        let windowSeconds: Double
        let sampleBytes: Int
        let measuredBytesPerSecond: Double
        let budgetBytesPerSecond: Double
        let utilization: Double
    }

    struct TelemetrySnapshot: Sendable {
        let queuedBytes: Int
        let sendStartDelayAverageMs: Double
        let sendStartDelayMaxMs: Double
        let sendCompletionAverageMs: Double
        let sendCompletionMaxMs: Double
        let keyframeSendAverageMs: Double
        let keyframeSendMaxMs: Double
        let packetPacerSleepAverageMs: Double
        let packetPacerSleepMaxMs: Int
        let packetPacerSleepCount: UInt64
        let stalePacketDrops: UInt64
        let generationAbortDrops: UInt64
        let nonKeyframeHoldDrops: UInt64
    }

    private struct PacketBudgetSample: Sendable {
        let timestamp: CFAbsoluteTime
        let bytes: Int
    }

    nonisolated static let packetBudgetWindowSeconds: CFAbsoluteTime = 0.75
    nonisolated static let packetBudgetMinWindowSeconds: CFAbsoluteTime = 0.20
    nonisolated static let packetPacerBurstWindowMs: Double = 6.0
    nonisolated static let packetPacerDebtToleranceMs: Double = 1.0
    nonisolated static let packetPacerMaxSleepMsPerPacket: Int = 12
    nonisolated static let packetPacerLogIntervalSeconds: CFAbsoluteTime = 2.0

    private let maxPayloadSize: Int
    private let mediaSecurityKey: MirageMediaPacketKey?
    private let sendPacket: @Sendable (Data) async throws -> Void
    private let onSendError: (@Sendable (Error) -> Void)?
    private let packetBufferPool: PacketBufferPool
    private let awdlExperimentEnabled = ProcessInfo.processInfo.environment["MIRAGE_AWDL_EXPERIMENT"] == "1"
    private var sendTask: Task<Void, Never>?
    /// Accessed from encoder callbacks; lifecycle is managed by start/stop.
    private nonisolated(unsafe) var sendContinuation: AsyncStream<WorkItem>.Continuation?
    // Snapshot read from encoder callbacks to tag enqueued frames.
    private nonisolated(unsafe) var generation: UInt32 = 0
    private nonisolated(unsafe) var queuedBytes: Int = 0
    private nonisolated(unsafe) var packetBudgetSamples: [PacketBudgetSample] = []
    private nonisolated(unsafe) var packetBudgetSampleBytes: Int = 0
    private nonisolated(unsafe) var dropNonKeyframesUntilKeyframe: Bool = false
    private nonisolated(unsafe) var latestKeyframeFrameNumber: UInt32 = 0
    private let queueLock = NSLock()

    private var pacerRateBps: Int = 0
    private var pacerTokensBytes: Double = 0
    private var pacerLastRefillTime: CFAbsoluteTime = 0
    private var pacerSleepTotalMs: Int = 0
    private var pacerSleepMaxMs: Int = 0
    private var pacerSleepPacketCount: Int = 0
    private var pacerLastLogTime: CFAbsoluteTime = 0
    private var sendStartDelayTotalMs: Double = 0
    private var sendStartDelayMaxMs: Double = 0
    private var sendStartDelayCount: UInt64 = 0
    private var sendCompletionTotalMs: Double = 0
    private var sendCompletionMaxMs: Double = 0
    private var sendCompletionCount: UInt64 = 0
    private var keyframeSendTotalMs: Double = 0
    private var keyframeSendMaxMs: Double = 0
    private var keyframeSendCount: UInt64 = 0
    private var stalePacketDropCount: UInt64 = 0
    private var generationAbortDropCount: UInt64 = 0
    private var nonKeyframeHoldDropCount: UInt64 = 0

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

    nonisolated static func packetPacerBurstWindowMilliseconds(
        isKeyframeBurst: Bool,
        totalFragments: Int
    ) -> Double {
        guard isKeyframeBurst else { return packetPacerBurstWindowMs }
        guard totalFragments > 0 else { return packetPacerBurstWindowMs }
        return packetPacerBurstWindowMs
    }

    nonisolated static func packetPacingParameters(
        targetRateBps: Int,
        packetBytes: Int,
        isKeyframeBurst: Bool,
        totalFragments: Int,
        pacingOverride: PacingOverride?
    ) -> (bytesPerSecond: Double, burstBytes: Double)? {
        guard isKeyframeBurst else { return nil }
        guard packetBytes > 0 else { return nil }

        let overrideRate = max(0, pacingOverride?.rateBps ?? 0)
        let effectiveRateBps = if targetRateBps > 0, overrideRate > 0 {
            min(targetRateBps, overrideRate)
        } else {
            max(targetRateBps, overrideRate)
        }
        guard effectiveRateBps > 0 else { return nil }

        let bytesPerSecond = max(1.0, Double(effectiveRateBps) / 8.0)
        let bytesPerMillisecond = max(1.0, bytesPerSecond / 1_000.0)
        let burstWindowMs = packetPacerBurstWindowMilliseconds(
            isKeyframeBurst: isKeyframeBurst,
            totalFragments: totalFragments
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

    init(
        maxPayloadSize: Int,
        mediaSecurityContext: MirageMediaSecurityContext? = nil,
        sendPacket: @escaping @Sendable (Data) async throws -> Void,
        onSendError: (@Sendable (Error) -> Void)? = nil
    ) {
        self.maxPayloadSize = maxPayloadSize
        mediaSecurityKey = mediaSecurityContext.map { MirageMediaSecurity.makePacketKey(context: $0) }
        self.sendPacket = sendPacket
        self.onSendError = onSendError
        packetBufferPool = PacketBufferPool(
            capacity: mirageHeaderSize + maxPayloadSize + MirageMediaSecurity.authTagLength
        )
    }

    func start() {
        guard sendTask == nil else { return }
        let (stream, continuation) = AsyncStream.makeStream(of: WorkItem.self, bufferingPolicy: .unbounded)
        sendContinuation = continuation
        queueLock.withLock {
            queuedBytes = 0
            packetBudgetSamples.removeAll(keepingCapacity: true)
            packetBudgetSampleBytes = 0
        }
        resetPacketPacerState(now: CFAbsoluteTimeGetCurrent())
        resetTelemetry()
        sendTask = Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            for await item in stream {
                await handle(item)
            }
        }
    }

    func stop() {
        sendContinuation?.finish()
        sendContinuation = nil
        sendTask?.cancel()
        sendTask = nil
        queueLock.withLock {
            queuedBytes = 0
            packetBudgetSamples.removeAll(keepingCapacity: true)
            packetBudgetSampleBytes = 0
        }
        resetPacketPacerState(now: CFAbsoluteTimeGetCurrent())
        resetTelemetry()
    }

    func setTargetBitrateBps(_ bitrate: Int?) {
        let sanitized = max(0, bitrate ?? 0)
        guard sanitized != pacerRateBps else { return }
        pacerRateBps = sanitized
        queueLock.withLock {
            packetBudgetSamples.removeAll(keepingCapacity: true)
            packetBudgetSampleBytes = 0
        }
        resetPacketPacerState(now: CFAbsoluteTimeGetCurrent())
    }

    func bumpGeneration(reason: String) {
        generation &+= 1
        MirageLogger.stream("Packet send generation bumped to \(generation) (\(reason))")
    }

    func resetQueue(reason: String) {
        generation &+= 1
        queueLock.withLock {
            queuedBytes = 0
            packetBudgetSamples.removeAll(keepingCapacity: true)
            packetBudgetSampleBytes = 0
        }
        resetPacketPacerState(now: CFAbsoluteTimeGetCurrent())
        MirageLogger.stream("Packet send queue reset (gen \(generation), \(reason))")
    }

    nonisolated func queuedBytesSnapshot() -> Int {
        queueLock.withLock { queuedBytes }
    }

    nonisolated func currentGenerationSnapshot() -> UInt32 {
        generation
    }

    func telemetrySnapshot() -> TelemetrySnapshot {
        let queuedBytesSnapshot = queueLock.withLock { self.queuedBytes }
        let sendStartDelayAverageMs = sendStartDelayCount > 0
            ? sendStartDelayTotalMs / Double(sendStartDelayCount)
            : 0
        let sendCompletionAverageMs = sendCompletionCount > 0
            ? sendCompletionTotalMs / Double(sendCompletionCount)
            : 0
        let keyframeSendAverageMs = keyframeSendCount > 0
            ? keyframeSendTotalMs / Double(keyframeSendCount)
            : 0
        let packetPacerSleepAverageMs = pacerSleepPacketCount > 0
            ? Double(pacerSleepTotalMs) / Double(pacerSleepPacketCount)
            : 0
        return TelemetrySnapshot(
            queuedBytes: queuedBytesSnapshot,
            sendStartDelayAverageMs: sendStartDelayAverageMs,
            sendStartDelayMaxMs: sendStartDelayMaxMs,
            sendCompletionAverageMs: sendCompletionAverageMs,
            sendCompletionMaxMs: sendCompletionMaxMs,
            keyframeSendAverageMs: keyframeSendAverageMs,
            keyframeSendMaxMs: keyframeSendMaxMs,
            packetPacerSleepAverageMs: packetPacerSleepAverageMs,
            packetPacerSleepMaxMs: pacerSleepMaxMs,
            packetPacerSleepCount: UInt64(pacerSleepPacketCount),
            stalePacketDrops: stalePacketDropCount,
            generationAbortDrops: generationAbortDropCount,
            nonKeyframeHoldDrops: nonKeyframeHoldDropCount
        )
    }

    func packetBudgetSnapshot(now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) -> PacketBudgetSnapshot? {
        guard pacerRateBps > 0 else { return nil }
        return queueLock.withLock {
            trimPacketBudgetSamplesLocked(now: now)
            guard !packetBudgetSamples.isEmpty else { return nil }
            let elapsed = max(Self.packetBudgetMinWindowSeconds, Self.packetBudgetWindowSeconds)
            let measuredBytesPerSecond = Double(packetBudgetSampleBytes) / elapsed
            let budgetBytesPerSecond = max(1.0, Double(pacerRateBps) / 8.0)
            let utilization = measuredBytesPerSecond / budgetBytesPerSecond
            return PacketBudgetSnapshot(
                targetBitrateBps: pacerRateBps,
                windowSeconds: elapsed,
                sampleBytes: packetBudgetSampleBytes,
                measuredBytesPerSecond: measuredBytesPerSecond,
                budgetBytesPerSecond: budgetBytesPerSecond,
                utilization: utilization
            )
        }
    }

    nonisolated static func shouldDuplicateParameterSetPacket(
        isExperimentEnabled: Bool,
        isKeyframe: Bool,
        fragmentIndex: Int,
        flags: FrameFlags
    ) -> Bool {
        guard isExperimentEnabled else { return false }
        guard isKeyframe else { return false }
        guard fragmentIndex == 0 else { return false }
        return flags.contains(.parameterSet)
    }

    nonisolated func enqueue(_ item: WorkItem) {
        guard sendContinuation != nil else { return }
        let accountedBytes = max(0, item.wireBytes)
        let estimatedPacketWireBytes = estimatedPacketWireBytes(for: item)
        let now = CFAbsoluteTimeGetCurrent()
        queueLock.withLock {
            queuedBytes += accountedBytes
            recordPacketBudgetSampleLocked(bytes: estimatedPacketWireBytes, now: now)
            if item.isKeyframe {
                dropNonKeyframesUntilKeyframe = true
                latestKeyframeFrameNumber = item.frameNumber
            }
        }
        sendContinuation?.yield(item)
    }

    private func handle(_ item: WorkItem) async {
        let accountedBytes = max(0, item.wireBytes)
        let (shouldDropNonKeyframes, newestKeyframe) = queueLock.withLock {
            (dropNonKeyframesUntilKeyframe, latestKeyframeFrameNumber)
        }
        if shouldDropNonKeyframes, !item.isKeyframe {
            nonKeyframeHoldDropCount &+= 1
            reduceQueuedBytes(accountedBytes)
            return
        }
        if item.isKeyframe, newestKeyframe > 0, item.frameNumber < newestKeyframe {
            stalePacketDropCount &+= 1
            reduceQueuedBytes(accountedBytes)
            MirageLogger.stream("Dropping stale keyframe \(item.frameNumber) (newest \(newestKeyframe))")
            return
        }
        guard item.generation == generation else {
            generationAbortDropCount &+= 1
            if item.isKeyframe {
                MirageLogger
                    .stream("Dropping stale keyframe \(item.frameNumber) (gen \(item.generation) != \(generation))")
                queueLock.withLock {
                    if latestKeyframeFrameNumber == item.frameNumber { dropNonKeyframesUntilKeyframe = false }
                }
            }
            reduceQueuedBytes(accountedBytes)
            return
        }

        await fragmentAndSendPackets(item, accountedBytes: accountedBytes)
        if item.isKeyframe {
            queueLock.withLock {
                if latestKeyframeFrameNumber == item.frameNumber { dropNonKeyframesUntilKeyframe = false }
            }
        }
    }

    private func fragmentAndSendPackets(_ item: WorkItem, accountedBytes: Int) async {
        let fragmentStartTime = CFAbsoluteTimeGetCurrent()
        var remainingQueuedBytes = max(0, accountedBytes)

        let maxPayload = maxPayloadSize
        let frameByteCount = max(0, item.frameByteCount)
        let dataFragmentCount = dataFragmentCount(for: frameByteCount, maxPayload: maxPayload)
        let fecBlockSize = max(0, item.fecBlockSize)
        let parityFragmentCount = parityFragmentCount(
            dataFragmentCount: dataFragmentCount,
            blockSize: fecBlockSize
        )
        let totalFragments = dataFragmentCount + parityFragmentCount
        let timestamp = UInt64(CMTimeGetSeconds(item.presentationTime) * 1_000_000_000)
        var didRecordSendStart = false

        var currentSequence = item.sequenceNumberStart
        for fragmentIndex in 0 ..< totalFragments {
            if item.generation != generation {
                generationAbortDropCount &+= 1
                MirageLogger
                    .stream("Aborting send for frame \(item.frameNumber) (gen \(item.generation) != \(generation))")
                if item.isKeyframe {
                    queueLock.withLock {
                        if latestKeyframeFrameNumber == item.frameNumber { dropNonKeyframesUntilKeyframe = false }
                    }
                }
                if remainingQueuedBytes > 0 { reduceQueuedBytes(remainingQueuedBytes) }
                return
            }

            var flags = item.additionalFlags
            if fragmentIndex > 0, flags.contains(.discontinuity) { flags.remove(.discontinuity) }
            if item.isKeyframe { flags.insert(.keyframe) }
            if fragmentIndex == totalFragments - 1 { flags.insert(.endOfFrame) }
            if item.isKeyframe, fragmentIndex == 0 { flags.insert(.parameterSet) }

            if fragmentIndex < dataFragmentCount {
                let start = fragmentIndex * maxPayload
                let end = min(start + maxPayload, frameByteCount)
                let fragmentSize = end - start
                guard fragmentSize > 0 else { continue }
                let checksum: UInt32 = if mediaSecurityKey == nil {
                    item.encodedData.withUnsafeBytes { frameBytes in
                        CRC32.calculate(UnsafeRawBufferPointer(rebasing: frameBytes[start ..< end]))
                    }
                } else {
                    0
                }
                var payloadFlags = flags
                if mediaSecurityKey != nil {
                    payloadFlags.insert(.encryptedPayload)
                }

                let header = FrameHeader(
                    flags: payloadFlags,
                    streamID: item.streamID,
                    sequenceNumber: currentSequence,
                    timestamp: timestamp,
                    frameNumber: item.frameNumber,
                    fragmentIndex: UInt16(fragmentIndex),
                    fragmentCount: UInt16(totalFragments),
                    fecBlockSize: UInt8(clamping: fecBlockSize),
                    payloadLength: UInt32(fragmentSize),
                    frameByteCount: UInt32(frameByteCount),
                    checksum: checksum,
                    contentRect: item.contentRect,
                    dimensionToken: item.dimensionToken,
                    epoch: item.epoch
                )

                let wirePayload: Data?
                if let mediaSecurityKey {
                    do {
                        wirePayload = try item.encodedData.withUnsafeBytes { frameBytes in
                            try MirageMediaSecurity.encryptVideoPayload(
                                UnsafeRawBufferPointer(rebasing: frameBytes[start ..< end]),
                                header: header,
                                key: mediaSecurityKey,
                                direction: .hostToClient
                            )
                        }
                    } catch {
                        MirageLogger.error(
                            .stream,
                            "Failed to encrypt video packet for stream \(item.streamID) frame \(item.frameNumber) seq \(currentSequence): \(error)"
                        )
                        continue
                    }
                } else {
                    wirePayload = nil
                }

                let packetPayloadLength = wirePayload?.count ?? fragmentSize
                let packetLength = mirageHeaderSize + packetPayloadLength
                await paceIfNeeded(
                    packetBytes: packetLength,
                    isKeyframeBurst: item.isKeyframe,
                    totalFragments: totalFragments,
                    pacingOverride: item.pacingOverride
                )

                let packetBuffer = packetBufferPool.acquire()
                packetBuffer.prepare(length: packetLength)
                packetBuffer.withMutableBytes { packetBytes in
                    guard packetBytes.count >= packetLength,
                          let baseAddress = packetBytes.baseAddress else {
                        return
                    }
                    let headerBuffer = UnsafeMutableRawBufferPointer(
                        start: baseAddress,
                        count: min(packetBytes.count, mirageHeaderSize)
                    )
                    header.serialize(into: headerBuffer)
                    if let wirePayload {
                        wirePayload.withUnsafeBytes { payloadBytes in
                            guard let payloadBase = payloadBytes.baseAddress else { return }
                            baseAddress.advanced(by: mirageHeaderSize).copyMemory(
                                from: payloadBase,
                                byteCount: wirePayload.count
                            )
                        }
                    } else {
                        item.encodedData.withUnsafeBytes { frameBytes in
                            let fragmentBytes = UnsafeRawBufferPointer(rebasing: frameBytes[start ..< end])
                            guard let fragmentBase = fragmentBytes.baseAddress else { return }
                            baseAddress.advanced(by: mirageHeaderSize).copyMemory(
                                from: fragmentBase,
                                byteCount: fragmentSize
                            )
                        }
                    }
                }

                let packet = packetBuffer.finalize(length: packetLength)
                let accountedPayloadBytes = fragmentSize
                remainingQueuedBytes = max(0, remainingQueuedBytes - accountedPayloadBytes)
                if !didRecordSendStart {
                    recordSendStartDelay(item: item, now: CFAbsoluteTimeGetCurrent())
                    didRecordSendStart = true
                }
                let duplicatePacket: Data? = if Self.shouldDuplicateParameterSetPacket(
                    isExperimentEnabled: awdlExperimentEnabled,
                    isKeyframe: item.isKeyframe,
                    fragmentIndex: fragmentIndex,
                    flags: flags
                ) {
                    Data(packet)
                } else {
                    nil
                }

                do {
                    try await sendPacket(packet)
                } catch {
                    packetBuffer.release()
                    if remainingQueuedBytes > 0 { reduceQueuedBytes(remainingQueuedBytes) }
                    onSendError?(error)
                    return
                }
                if let duplicatePacket {
                    do {
                        try await sendPacket(duplicatePacket)
                    } catch {
                        packetBuffer.release()
                        reduceQueuedBytes(accountedPayloadBytes)
                        if remainingQueuedBytes > 0 { reduceQueuedBytes(remainingQueuedBytes) }
                        onSendError?(error)
                        return
                    }
                }
                packetBuffer.release()
                reduceQueuedBytes(accountedPayloadBytes)
            } else if parityFragmentCount > 0 {
                let parityIndex = fragmentIndex - dataFragmentCount
                let blockIndex = parityIndex
                let blockSize = fecBlockSize
                guard blockSize > 0 else { continue }
                let blockStart = blockIndex * blockSize
                let blockEnd = min(blockStart + blockSize, dataFragmentCount)
                guard blockStart < blockEnd else { continue }

                let parityLength = parityPayloadLength(
                    frameByteCount: frameByteCount,
                    blockStart: blockStart,
                    maxPayload: maxPayload
                )
                let parityData = computeParity(
                    encodedData: item.encodedData,
                    frameByteCount: frameByteCount,
                    blockStart: blockStart,
                    blockEnd: blockEnd,
                    payloadLength: parityLength,
                    maxPayload: maxPayload
                )
                guard !parityData.isEmpty else { continue }

                var parityFlags = flags
                parityFlags.insert(.fecParity)
                if mediaSecurityKey != nil {
                    parityFlags.insert(.encryptedPayload)
                }

                let checksum: UInt32 = mediaSecurityKey == nil ? CRC32.calculate(parityData) : 0
                let header = FrameHeader(
                    flags: parityFlags,
                    streamID: item.streamID,
                    sequenceNumber: currentSequence,
                    timestamp: timestamp,
                    frameNumber: item.frameNumber,
                    fragmentIndex: UInt16(fragmentIndex),
                    fragmentCount: UInt16(totalFragments),
                    fecBlockSize: UInt8(clamping: fecBlockSize),
                    payloadLength: UInt32(parityData.count),
                    frameByteCount: UInt32(frameByteCount),
                    checksum: checksum,
                    contentRect: item.contentRect,
                    dimensionToken: item.dimensionToken,
                    epoch: item.epoch
                )

                let wirePayload: Data
                if let mediaSecurityKey {
                    do {
                        wirePayload = try parityData.withUnsafeBytes { parityBytes in
                            try MirageMediaSecurity.encryptVideoPayload(
                                parityBytes,
                                header: header,
                                key: mediaSecurityKey,
                                direction: .hostToClient
                            )
                        }
                    } catch {
                        MirageLogger.error(
                            .stream,
                            "Failed to encrypt parity packet for stream \(item.streamID) frame \(item.frameNumber) seq \(currentSequence): \(error)"
                        )
                        continue
                    }
                } else {
                    wirePayload = parityData
                }

                await paceIfNeeded(
                    packetBytes: mirageHeaderSize + wirePayload.count,
                    isKeyframeBurst: item.isKeyframe,
                    totalFragments: totalFragments,
                    pacingOverride: item.pacingOverride
                )

                let packetBuffer = packetBufferPool.acquire()
                packetBuffer.prepare(length: mirageHeaderSize + wirePayload.count)
                packetBuffer.withMutableBytes { packetBytes in
                    guard packetBytes.count >= mirageHeaderSize + wirePayload.count,
                          let baseAddress = packetBytes.baseAddress else {
                        return
                    }
                    let headerBuffer = UnsafeMutableRawBufferPointer(
                        start: baseAddress,
                        count: min(packetBytes.count, mirageHeaderSize)
                    )
                    header.serialize(into: headerBuffer)
                    wirePayload.withUnsafeBytes { payloadBytes in
                        guard let payloadBase = payloadBytes.baseAddress else { return }
                        baseAddress.advanced(by: mirageHeaderSize).copyMemory(
                            from: payloadBase,
                            byteCount: wirePayload.count
                        )
                    }
                }

                let packet = packetBuffer.finalize(length: mirageHeaderSize + wirePayload.count)
                let accountedPayloadBytes = maxPayload
                remainingQueuedBytes = max(0, remainingQueuedBytes - accountedPayloadBytes)
                if !didRecordSendStart {
                    recordSendStartDelay(item: item, now: CFAbsoluteTimeGetCurrent())
                    didRecordSendStart = true
                }

                do {
                    try await sendPacket(packet)
                } catch {
                    packetBuffer.release()
                    if remainingQueuedBytes > 0 { reduceQueuedBytes(remainingQueuedBytes) }
                    onSendError?(error)
                    return
                }
                packetBuffer.release()
                reduceQueuedBytes(accountedPayloadBytes)
            }
            currentSequence += 1
        }

        if remainingQueuedBytes > 0 { reduceQueuedBytes(remainingQueuedBytes) }
        recordSendCompletion(item: item, startedAt: fragmentStartTime, completedAt: CFAbsoluteTimeGetCurrent())

        if item.isKeyframe {
            let fragmentDurationMs = (CFAbsoluteTimeGetCurrent() - fragmentStartTime) * 1000
            let roundedDuration = (fragmentDurationMs * 100).rounded() / 100
            let bytesKB = Double(item.encodedData.count) / 1024.0
            let roundedBytes = (bytesKB * 10).rounded() / 10
            MirageLogger
                .timing(
                    "\(item.logPrefix) \(item.frameNumber) keyframe: \(roundedDuration)ms, \(totalFragments) packets, \(roundedBytes)KB"
                )
        }
    }

    private func dataFragmentCount(for frameByteCount: Int, maxPayload: Int) -> Int {
        guard frameByteCount > 0, maxPayload > 0 else { return 0 }
        return (frameByteCount + maxPayload - 1) / maxPayload
    }

    private func parityFragmentCount(dataFragmentCount: Int, blockSize: Int) -> Int {
        guard dataFragmentCount > 0, blockSize > 1 else { return 0 }
        return (dataFragmentCount + blockSize - 1) / blockSize
    }

    private func parityPayloadLength(frameByteCount: Int, blockStart: Int, maxPayload: Int) -> Int {
        guard frameByteCount > 0, maxPayload > 0 else { return 0 }
        let start = blockStart * maxPayload
        let remaining = max(0, frameByteCount - start)
        return min(maxPayload, remaining)
    }

    private nonisolated func reduceQueuedBytes(_ bytes: Int) {
        guard bytes > 0 else { return }
        queueLock.withLock {
            queuedBytes = max(0, queuedBytes - bytes)
        }
    }

    private nonisolated func estimatedPacketWireBytes(for item: WorkItem) -> Int {
        let payloadBytes = max(0, item.wireBytes)
        let maxPayload = max(1, maxPayloadSize)
        let frameByteCount = max(0, item.frameByteCount)
        let dataFragments = frameByteCount > 0 ? (frameByteCount + maxPayload - 1) / maxPayload : 0
        let blockSize = max(0, item.fecBlockSize)
        let parityFragments = blockSize > 1 ? (dataFragments + blockSize - 1) / blockSize : 0
        let totalFragments = dataFragments + parityFragments
        let authOverheadPerPacket = mediaSecurityKey == nil ? 0 : MirageMediaSecurity.authTagLength
        let packetOverheadBytes = totalFragments * (mirageHeaderSize + authOverheadPerPacket)
        var estimatedBytes = payloadBytes + packetOverheadBytes
        if awdlExperimentEnabled, item.isKeyframe, dataFragments > 0 {
            let firstPayload = min(maxPayload, frameByteCount)
            estimatedBytes += mirageHeaderSize + authOverheadPerPacket + firstPayload
        }
        return max(0, estimatedBytes)
    }

    private nonisolated func trimPacketBudgetSamplesLocked(now: CFAbsoluteTime) {
        let cutoff = now - Self.packetBudgetWindowSeconds
        while let first = packetBudgetSamples.first, first.timestamp < cutoff {
            packetBudgetSampleBytes = max(0, packetBudgetSampleBytes - first.bytes)
            packetBudgetSamples.removeFirst()
        }
    }

    private nonisolated func recordPacketBudgetSampleLocked(bytes: Int, now: CFAbsoluteTime) {
        guard bytes > 0 else {
            trimPacketBudgetSamplesLocked(now: now)
            return
        }
        packetBudgetSamples.append(PacketBudgetSample(timestamp: now, bytes: bytes))
        packetBudgetSampleBytes += bytes
        trimPacketBudgetSamplesLocked(now: now)
    }

    private func computeParity(
        encodedData: Data,
        frameByteCount: Int,
        blockStart: Int,
        blockEnd: Int,
        payloadLength: Int,
        maxPayload: Int
    )
    -> Data {
        guard payloadLength > 0 else { return Data() }
        var parity = Data(repeating: 0, count: payloadLength)
        parity.withUnsafeMutableBytes { parityBytes in
            let parityPtr = parityBytes.bindMemory(to: UInt8.self)
            guard let parityBase = parityPtr.baseAddress else { return }
            encodedData.withUnsafeBytes { dataBytes in
                let dataPtr = dataBytes.bindMemory(to: UInt8.self)
                guard let dataBase = dataPtr.baseAddress else { return }
                for fragmentIndex in blockStart ..< blockEnd {
                    let start = fragmentIndex * maxPayload
                    let remaining = max(0, frameByteCount - start)
                    let fragmentSize = min(maxPayload, remaining)
                    guard fragmentSize > 0 else { continue }
                    let sourcePtr = dataBase.advanced(by: start)
                    let bytesToXor = min(fragmentSize, payloadLength)
                    let src = sourcePtr
                    for i in 0 ..< bytesToXor {
                        parityBase[i] ^= src[i]
                    }
                }
            }
        }
        return parity
    }

    private func paceIfNeeded(
        packetBytes: Int,
        isKeyframeBurst: Bool,
        totalFragments: Int,
        pacingOverride: PacingOverride?
    ) async {
        guard let parameters = Self.packetPacingParameters(
            targetRateBps: pacerRateBps,
            packetBytes: packetBytes,
            isKeyframeBurst: isKeyframeBurst,
            totalFragments: totalFragments,
            pacingOverride: pacingOverride
        ) else { return }

        let bytesPerSecond = parameters.bytesPerSecond
        let bytesPerMillisecond = max(1.0, bytesPerSecond / 1_000.0)
        let burstBytes = parameters.burstBytes
        refillPacketPacerTokens(
            now: CFAbsoluteTimeGetCurrent(),
            bytesPerSecond: bytesPerSecond,
            burstBytes: burstBytes
        )

        while true {
            let sleepMs = Self.packetPacerSleepMilliseconds(
                tokensBeforeSend: pacerTokensBytes,
                packetBytes: packetBytes,
                bytesPerMillisecond: bytesPerMillisecond
            )
            guard sleepMs > 0 else { break }

            try? await Task.sleep(for: .milliseconds(Int64(sleepMs)))
            pacerSleepTotalMs += sleepMs
            pacerSleepMaxMs = max(pacerSleepMaxMs, sleepMs)
            pacerSleepPacketCount += 1

            let now = CFAbsoluteTimeGetCurrent()
            refillPacketPacerTokens(
                now: now,
                bytesPerSecond: bytesPerSecond,
                burstBytes: burstBytes
            )
            logPacketPacingIfNeeded(now: now)
        }

        pacerTokensBytes -= Double(packetBytes)
    }

    private func resetPacketPacerState(now: CFAbsoluteTime) {
        pacerTokensBytes = 0
        pacerLastRefillTime = 0
        pacerSleepTotalMs = 0
        pacerSleepMaxMs = 0
        pacerSleepPacketCount = 0
        pacerLastLogTime = now
    }

    private func refillPacketPacerTokens(
        now: CFAbsoluteTime,
        bytesPerSecond: Double,
        burstBytes: Double
    ) {
        if pacerLastRefillTime == 0 {
            pacerLastRefillTime = now
            pacerTokensBytes = burstBytes
            return
        }

        let elapsed = max(0.0, now - pacerLastRefillTime)
        pacerLastRefillTime = now
        pacerTokensBytes = min(
            burstBytes,
            max(-burstBytes, pacerTokensBytes + elapsed * bytesPerSecond)
        )
    }

    private func logPacketPacingIfNeeded(now: CFAbsoluteTime) {
        guard MirageLogger.isEnabled(.stream) else { return }
        guard pacerSleepPacketCount > 0 else { return }
        guard pacerLastLogTime == 0 || now - pacerLastLogTime >= Self.packetPacerLogIntervalSeconds else { return }

        MirageLogger.stream(
            "Packet pacer: sleeps=\(pacerSleepPacketCount), totalMs=\(pacerSleepTotalMs), maxMs=\(pacerSleepMaxMs)"
        )
        pacerLastLogTime = now
    }

    private func resetTelemetry() {
        sendStartDelayTotalMs = 0
        sendStartDelayMaxMs = 0
        sendStartDelayCount = 0
        sendCompletionTotalMs = 0
        sendCompletionMaxMs = 0
        sendCompletionCount = 0
        keyframeSendTotalMs = 0
        keyframeSendMaxMs = 0
        keyframeSendCount = 0
        stalePacketDropCount = 0
        generationAbortDropCount = 0
        nonKeyframeHoldDropCount = 0
    }

    private func recordSendStartDelay(item: WorkItem, now: CFAbsoluteTime) {
        let delayMs = max(0, (now - item.encodedAt) * 1000)
        sendStartDelayTotalMs += delayMs
        sendStartDelayMaxMs = max(sendStartDelayMaxMs, delayMs)
        sendStartDelayCount &+= 1
    }

    private func recordSendCompletion(item: WorkItem, startedAt: CFAbsoluteTime, completedAt: CFAbsoluteTime) {
        let completionMs = max(0, (completedAt - item.encodedAt) * 1000)
        sendCompletionTotalMs += completionMs
        sendCompletionMaxMs = max(sendCompletionMaxMs, completionMs)
        sendCompletionCount &+= 1

        if item.isKeyframe {
            let keyframeMs = max(0, (completedAt - startedAt) * 1000)
            keyframeSendTotalMs += keyframeMs
            keyframeSendMaxMs = max(keyframeSendMaxMs, keyframeMs)
            keyframeSendCount &+= 1
        }
    }
}

#endif
