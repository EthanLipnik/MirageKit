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
        let onSendStart: (@Sendable () -> Void)?
        let onSendComplete: (@Sendable () -> Void)?
    }

    private let maxPayloadSize: Int
    private let mediaSecurityKey: MirageMediaPacketKey?
    private let onEncodedFrame: @Sendable (Data, FrameHeader, @escaping @Sendable () -> Void) -> Void
    private let packetBufferPool: PacketBufferPool
    private let awdlExperimentEnabled = ProcessInfo.processInfo.environment["MIRAGE_AWDL_EXPERIMENT"] == "1"
    private var sendTask: Task<Void, Never>?
    /// Accessed from encoder callbacks; lifecycle is managed by start/stop.
    private nonisolated(unsafe) var sendContinuation: AsyncStream<WorkItem>.Continuation?
    // Snapshot read from encoder callbacks to tag enqueued frames.
    private nonisolated(unsafe) var generation: UInt32 = 0
    private nonisolated(unsafe) var queuedBytes: Int = 0
    private nonisolated(unsafe) var dropNonKeyframesUntilKeyframe: Bool = false
    private nonisolated(unsafe) var latestKeyframeFrameNumber: UInt32 = 0
    private let queueLock = NSLock()

    private var pacerRateBps: Int = 0
    private var pacerRateBytesPerSecond: Double = 0
    private var pacerTokens: Double = 0
    private var pacerLastTime: CFAbsoluteTime = 0
    private var pacerMaxBurstBytes: Double = 0
    private let pacerBurstSeconds: Double = 0.0025
    private let pacerMinBurstPackets: Int = 8
    private let pacerMaxBurstPackets: Int = 64

    init(
        maxPayloadSize: Int,
        mediaSecurityContext: MirageMediaSecurityContext? = nil,
        onEncodedFrame: @escaping @Sendable (Data, FrameHeader, @escaping @Sendable () -> Void) -> Void
    ) {
        self.maxPayloadSize = maxPayloadSize
        mediaSecurityKey = mediaSecurityContext.map { MirageMediaSecurity.makePacketKey(context: $0) }
        self.onEncodedFrame = onEncodedFrame
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
        }
        resetPacerState(for: pacerRateBps)
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
        }
    }

    func setTargetBitrateBps(_ bitrate: Int?) {
        let sanitized = max(0, bitrate ?? 0)
        guard sanitized != pacerRateBps else { return }
        resetPacerState(for: sanitized)
    }

    func bumpGeneration(reason: String) {
        generation &+= 1
        MirageLogger.stream("Packet send generation bumped to \(generation) (\(reason))")
    }

    func resetQueue(reason: String) {
        generation &+= 1
        queueLock.withLock {
            queuedBytes = 0
        }
        MirageLogger.stream("Packet send queue reset (gen \(generation), \(reason))")
    }

    nonisolated func queuedBytesSnapshot() -> Int {
        queueLock.withLock { queuedBytes }
    }

    nonisolated func currentGenerationSnapshot() -> UInt32 {
        generation
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
        queueLock.withLock {
            queuedBytes += accountedBytes
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
            reduceQueuedBytes(accountedBytes)
            return
        }
        if item.isKeyframe, newestKeyframe > 0, item.frameNumber < newestKeyframe {
            reduceQueuedBytes(accountedBytes)
            MirageLogger.stream("Dropping stale keyframe \(item.frameNumber) (newest \(newestKeyframe))")
            return
        }
        guard item.generation == generation else {
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

        if item.isKeyframe { item.onSendStart?() }
        await fragmentAndSendPackets(item, accountedBytes: accountedBytes)
        if item.isKeyframe {
            item.onSendComplete?()
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

        var currentSequence = item.sequenceNumberStart
        for fragmentIndex in 0 ..< totalFragments {
            if item.generation != generation {
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
                await paceIfNeeded(packetBytes: packetLength)

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
                let releasePacket: @Sendable () -> Void = { [weak self] in
                    packetBuffer.release()
                    self?.reduceQueuedBytes(accountedPayloadBytes)
                }
                onEncodedFrame(packet, header, releasePacket)
                if Self.shouldDuplicateParameterSetPacket(
                    isExperimentEnabled: awdlExperimentEnabled,
                    isKeyframe: item.isKeyframe,
                    fragmentIndex: fragmentIndex,
                    flags: flags
                ) {
                    onEncodedFrame(Data(packet), header, {})
                }
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

                await paceIfNeeded(packetBytes: mirageHeaderSize + wirePayload.count)

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
                let releasePacket: @Sendable () -> Void = { [weak self] in
                    packetBuffer.release()
                    self?.reduceQueuedBytes(accountedPayloadBytes)
                }
                onEncodedFrame(packet, header, releasePacket)
            }
            currentSequence += 1
        }

        if remainingQueuedBytes > 0 { reduceQueuedBytes(remainingQueuedBytes) }

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

    private func resetPacerState(for bitrateBps: Int) {
        pacerRateBps = bitrateBps
        pacerLastTime = CFAbsoluteTimeGetCurrent()
        guard bitrateBps > 0 else {
            pacerRateBytesPerSecond = 0
            pacerTokens = 0
            pacerMaxBurstBytes = 0
            return
        }

        pacerRateBytesPerSecond = Double(bitrateBps) / 8.0
        let minBurstBytes = Double(maxPayloadSize * pacerMinBurstPackets)
        let maxBurstBytes = Double(maxPayloadSize * pacerMaxBurstPackets)
        let burstFromRate = pacerRateBytesPerSecond * pacerBurstSeconds
        pacerMaxBurstBytes = min(maxBurstBytes, max(minBurstBytes, burstFromRate))
        pacerTokens = pacerMaxBurstBytes
    }

    private func paceIfNeeded(packetBytes: Int) async {
        guard pacerRateBps > 0, packetBytes > 0 else { return }

        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = max(0, now - pacerLastTime)
        if elapsed > 0 {
            pacerTokens = min(pacerMaxBurstBytes, pacerTokens + elapsed * pacerRateBytesPerSecond)
        }
        pacerLastTime = now

        let packetCost = Double(packetBytes)
        guard pacerTokens < packetCost else {
            pacerTokens -= packetCost
            return
        }

        let deficit = packetCost - pacerTokens
        pacerTokens = 0
        let waitSeconds = deficit / pacerRateBytesPerSecond
        guard waitSeconds > 0 else { return }
        do {
            try await Task.sleep(for: .seconds(waitSeconds))
        } catch {
            return
        }
        pacerLastTime = CFAbsoluteTimeGetCurrent()
    }
}

#endif
