import Foundation
import CoreMedia
import CoreGraphics

#if os(macOS)

actor StreamPacketSender {
    struct WorkItem: Sendable {
        let encodedData: Data
        let isKeyframe: Bool
        let presentationTime: CMTime
        let contentRect: CGRect
        let streamID: StreamID
        let frameNumber: UInt32
        let sequenceNumberStart: UInt32
        let additionalFlags: FrameFlags
        let dimensionToken: UInt16
        let logPrefix: String
        let generation: UInt32
    }

    private let maxPayloadSize: Int
    private let onEncodedFrame: @Sendable (Data, FrameHeader) -> Void
    private var sendTask: Task<Void, Never>?
    // Accessed from encoder callbacks; lifecycle is managed by start/stop.
    nonisolated(unsafe) private var sendContinuation: AsyncStream<WorkItem>.Continuation?
    // Snapshot read from encoder callbacks to tag enqueued frames.
    nonisolated(unsafe) private var generation: UInt32 = 0
    nonisolated(unsafe) private var queuedBytes: Int = 0
    private let queueLock = NSLock()
    private let basePacingBurstSize = 16
    private let pacingThresholdBytes = 512 * 1024
    private let basePacingDelay = Duration.milliseconds(1)
    private let largeFrameThresholdBytes = 800 * 1024
    private let hugeFrameThresholdBytes = 1_500 * 1024

    init(maxPayloadSize: Int, onEncodedFrame: @escaping @Sendable (Data, FrameHeader) -> Void) {
        self.maxPayloadSize = maxPayloadSize
        self.onEncodedFrame = onEncodedFrame
    }

    func start() {
        guard sendTask == nil else { return }
        let (stream, continuation) = AsyncStream.makeStream(of: WorkItem.self, bufferingPolicy: .unbounded)
        sendContinuation = continuation
        queueLock.withLock {
            queuedBytes = 0
        }
        sendTask = Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            for await item in stream {
                await self.handle(item)
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

    nonisolated func enqueue(_ item: WorkItem) {
        guard sendContinuation != nil else { return }
        queueLock.withLock {
            queuedBytes += item.encodedData.count
        }
        sendContinuation?.yield(item)
    }

    private func handle(_ item: WorkItem) async {
        guard item.generation == generation else {
            if item.isKeyframe {
                MirageLogger.stream("Dropping stale keyframe \(item.frameNumber) (gen \(item.generation) != \(generation))")
            }
            queueLock.withLock {
                queuedBytes = max(0, queuedBytes - item.encodedData.count)
            }
            return
        }

        await fragmentAndSendPackets(item)
        queueLock.withLock {
            queuedBytes = max(0, queuedBytes - item.encodedData.count)
        }
    }

    private func fragmentAndSendPackets(_ item: WorkItem) async {
        let fragmentStartTime = CFAbsoluteTimeGetCurrent()

        let maxPayload = maxPayloadSize
        let totalFragments = (item.encodedData.count + maxPayload - 1) / maxPayload
        let timestamp = UInt64(CMTimeGetSeconds(item.presentationTime) * 1_000_000_000)

        let (burstSize, pacingDelay) = pacingConfig(for: item.encodedData.count, totalFragments: totalFragments)
        let burstCount = max(1, (totalFragments + burstSize - 1) / burstSize)
        let shouldPace = item.encodedData.count >= pacingThresholdBytes && burstCount > 1

        var currentSequence = item.sequenceNumberStart

        for burstIndex in 0..<burstCount {
            if item.generation != generation {
                MirageLogger.stream("Aborting send for frame \(item.frameNumber) (gen \(item.generation) != \(generation))")
                return
            }

            let burstStart = burstIndex * burstSize
            let burstEnd = min(burstStart + burstSize, totalFragments)

            for fragmentIndex in burstStart..<burstEnd {
                let start = fragmentIndex * maxPayload
                let end = min(start + maxPayload, item.encodedData.count)
                let fragmentData = item.encodedData.subdata(in: start..<end)

                var flags = item.additionalFlags
                if item.isKeyframe { flags.insert(.keyframe) }
                if fragmentIndex == totalFragments - 1 { flags.insert(.endOfFrame) }
                if item.isKeyframe && fragmentIndex == 0 { flags.insert(.parameterSet) }

                let header = FrameHeader(
                    flags: flags,
                    streamID: item.streamID,
                    sequenceNumber: currentSequence,
                    timestamp: timestamp,
                    frameNumber: item.frameNumber,
                    fragmentIndex: UInt16(fragmentIndex),
                    fragmentCount: UInt16(totalFragments),
                    payloadLength: UInt32(fragmentData.count),
                    checksum: CRC32.calculate(fragmentData),
                    contentRect: item.contentRect,
                    dimensionToken: item.dimensionToken
                )

                currentSequence += 1

                var packet = header.serialize()
                packet.append(fragmentData)

                onEncodedFrame(packet, header)
            }

            if shouldPace && burstIndex < burstCount - 1 {
                try? await Task.sleep(for: pacingDelay)
            }
        }

        if item.isKeyframe {
            let fragmentDurationMs = (CFAbsoluteTimeGetCurrent() - fragmentStartTime) * 1000
            let roundedDuration = (fragmentDurationMs * 100).rounded() / 100
            let bytesKB = Double(item.encodedData.count) / 1024.0
            let roundedBytes = (bytesKB * 10).rounded() / 10
            MirageLogger.timing("\(item.logPrefix) \(item.frameNumber) keyframe: \(roundedDuration)ms, \(totalFragments) packets, \(roundedBytes)KB")
        }
    }

    private func pacingConfig(for encodedBytes: Int, totalFragments: Int) -> (burstSize: Int, pacingDelay: Duration) {
        if encodedBytes >= hugeFrameThresholdBytes {
            return (burstSize: min(32, totalFragments), pacingDelay: .microseconds(250))
        }
        if encodedBytes >= largeFrameThresholdBytes {
            return (burstSize: min(24, totalFragments), pacingDelay: .microseconds(500))
        }
        return (burstSize: min(basePacingBurstSize, totalFragments), pacingDelay: basePacingDelay)
    }
}

#endif
