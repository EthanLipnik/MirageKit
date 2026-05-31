//
//  StreamPacketSenderRegressionTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/30/26.
//

#if os(macOS)
@testable import MirageKitHost
import CoreGraphics
import CoreMedia
import Foundation
import MirageKit
import Testing

@Suite("Stream Packet Sender Regression")
struct StreamPacketSenderRegressionTests {
    @Test("Live media profiles use unreliable queued video transport")
    func liveMediaProfilesUseUnreliableQueuedVideoTransport() {
        let profiles: [MirageMediaPathProfile] = [
            .awdlRadio,
            .localWiFi,
            .wired,
            .proximityWiredLike,
            .vpnOrOverlay,
            .other,
            .unknown,
        ]

        for profile in profiles {
            #expect(MirageVideoTransportMode.defaultMode(for: profile) == .unreliableQueued)
        }
    }

    @Test("Reliable ordered mode sends only data fragments sequentially")
    func reliableOrderedModeSendsOnlyDataFragmentsSequentially() async throws {
        let reliablePackets = Locked<[StreamPacketSenderReliablePacketSummary]>([])
        let unreliableSendCount = Locked(0)
        let inFlightReliableSendCount = Locked(0)
        let maxInFlightReliableSendCount = Locked(0)
        let sender = StreamPacketSender(
            maxPayloadSize: 4,
            sendPacket: { _, onComplete in
                unreliableSendCount.withLock { $0 += 1 }
                onComplete(nil)
            },
            sendPacketReliably: { packet in
                guard let header = FrameHeader.deserialize(from: packet) else {
                    Issue.record("Failed to deserialize reliable packet")
                    return
                }
                let inFlight = inFlightReliableSendCount.withLock { count in
                    count += 1
                    return count
                }
                maxInFlightReliableSendCount.withLock { $0 = max($0, inFlight) }
                reliablePackets.withLock {
                    $0.append(StreamPacketSenderReliablePacketSummary(
                        frameNumber: header.frameNumber,
                        sequenceNumber: header.sequenceNumber,
                        fragmentIndex: Int(header.fragmentIndex),
                        fragmentCount: Int(header.fragmentCount),
                        fecBlockSize: Int(header.fecBlockSize),
                        isFECParity: header.flags.contains(.fecParity)
                    ))
                }
                try await Task.sleep(for: .milliseconds(10))
                inFlightReliableSendCount.withLock { $0 -= 1 }
            },
            videoTransportMode: .reliableOrdered,
            duplicatesParameterSetPackets: true
        )

        await sender.start()
        let generation = sender.currentGeneration
        sender.enqueue(
            makeStreamPacketWorkItem(
                payload: makeStreamPacketPayload(byteCount: 10),
                streamID: 40,
                frameNumber: 11,
                sequenceNumberStart: 90,
                generation: generation,
                isKeyframe: true,
                fecBlockSize: 1
            )
        )

        try await waitForStreamPacketCondition(timeout: .seconds(2)) {
            reliablePackets.read { $0.count } == 3
        }
        try await waitForStreamPacketQueuedBytesToDrain(sender)

        #expect(unreliableSendCount.read { $0 } == 0)
        #expect(maxInFlightReliableSendCount.read { $0 } == 1)
        #expect(reliablePackets.read { $0 } == [
            StreamPacketSenderReliablePacketSummary(
                frameNumber: 11,
                sequenceNumber: 90,
                fragmentIndex: 0,
                fragmentCount: 3,
                fecBlockSize: 0,
                isFECParity: false
            ),
            StreamPacketSenderReliablePacketSummary(
                frameNumber: 11,
                sequenceNumber: 91,
                fragmentIndex: 1,
                fragmentCount: 3,
                fecBlockSize: 0,
                isFECParity: false
            ),
            StreamPacketSenderReliablePacketSummary(
                frameNumber: 11,
                sequenceNumber: 92,
                fragmentIndex: 2,
                fragmentCount: 3,
                fecBlockSize: 0,
                isFECParity: false
            ),
        ])

        await sender.stop()
    }

    @Test("Unreliable keyframes duplicate parameter-set packet when enabled")
    func unreliableKeyframesDuplicateParameterSetPacketWhenEnabled() async throws {
        let sentHeaders = Locked<[FrameHeader]>([])
        let sender = StreamPacketSender(
            maxPayloadSize: 4,
            sendPacket: { packet, onComplete in
                guard let header = FrameHeader.deserialize(from: packet) else {
                    Issue.record("Failed to deserialize submitted packet")
                    onComplete(nil)
                    return
                }
                sentHeaders.withLock { $0.append(header) }
                onComplete(nil)
            },
            videoTransportMode: .unreliableQueued,
            duplicatesParameterSetPackets: true
        )

        await sender.start()
        let generation = sender.currentGeneration
        sender.enqueue(
            makeStreamPacketWorkItem(
                payload: makeStreamPacketPayload(byteCount: 10),
                streamID: 40,
                frameNumber: 12,
                sequenceNumberStart: 120,
                generation: generation,
                isKeyframe: true
            )
        )

        try await waitForStreamPacketCondition(timeout: .seconds(2)) {
            sentHeaders.read { $0.count } == 4
        }
        try await waitForStreamPacketQueuedBytesToDrain(sender)

        let headers = sentHeaders.read { $0 }
        #expect(headers.map { Int($0.fragmentIndex) } == [0, 0, 1, 2])
        #expect(headers.filter { $0.fragmentIndex == 0 && $0.flags.contains(.parameterSet) }.count == 2)
        #expect(headers.map(\.sequenceNumber) == [120, 120, 121, 122])

        await sender.stop()
    }

    @Test("Sender-local deadline-past P-frames still send")
    func senderLocalDeadlinePastPFramesStillSend() async throws {
        let submittedPackets = Locked<[StreamPacketSenderSubmittedPacket]>([])
        let dependencyDropCount = Locked(0)
        let sender = StreamPacketSender(
            maxPayloadSize: 512,
            sendPacket: { packet, onComplete in
                guard let header = FrameHeader.deserialize(from: packet) else {
                    Issue.record("Failed to deserialize submitted packet")
                    onComplete(nil)
                    return
                }
                submittedPackets.withLock {
                    $0.append(StreamPacketSenderSubmittedPacket(frameNumber: header.frameNumber))
                }
                onComplete(nil)
            },
            onDependencyFrameDropped: { _, _, _ in dependencyDropCount.withLock { $0 += 1 } }
        )

        await sender.start()
        let generation = sender.currentGeneration
        let expiredDeadline = CFAbsoluteTimeGetCurrent() - 1
        for frameNumber in 1 ... 2 {
            sender.enqueue(
                makeStreamPacketWorkItem(
                    payload: makeStreamPacketPayload(byteCount: 128),
                    streamID: 40,
                    frameNumber: UInt32(frameNumber),
                    sequenceNumberStart: UInt32(frameNumber * 10),
                    generation: generation,
                    sendDeadline: expiredDeadline
                )
            )
        }

        try await waitForStreamPacketSubmissionCount(submittedPackets, expectedCount: 2)

        #expect(submittedPackets.read { $0.map(\.frameNumber) } == [1, 2])
        #expect(dependencyDropCount.read { $0 == 0 })
        let localSnapshot = await sender.telemetrySnapshot
        #expect(localSnapshot.senderLocalDeadlineDrops == 0)
        #expect(localSnapshot.lateNonKeyframeSends == 2)
        #expect(localSnapshot.stalePacketDrops == 0)
        #expect(await !sender.requiresDependencyRecoveryKeyframe())
        await sender.stop()
    }

    @Test("Repeated sender-local deadline-past P-frames enter stale-chain repair after two late sends")
    func repeatedSenderLocalDeadlinePastPFramesEnterStaleChainRepairAfterTwoLateSends() async throws {
        let submittedPackets = Locked<[StreamPacketSenderSubmittedPacket]>([])
        let dependencyDropCount = Locked(0)
        let sender = StreamPacketSender(
            maxPayloadSize: 512,
            sendPacket: { packet, onComplete in
                guard let header = FrameHeader.deserialize(from: packet) else {
                    Issue.record("Failed to deserialize submitted packet")
                    onComplete(nil)
                    return
                }
                submittedPackets.withLock {
                    $0.append(StreamPacketSenderSubmittedPacket(frameNumber: header.frameNumber))
                }
                onComplete(nil)
            },
            onDependencyFrameDropped: { _, _, _ in dependencyDropCount.withLock { $0 += 1 } }
        )

        await sender.start()
        let generation = sender.currentGeneration
        let expiredDeadline = CFAbsoluteTimeGetCurrent() - 1
        for frameNumber in 1 ... 3 {
            sender.enqueue(
                makeStreamPacketWorkItem(
                    payload: makeStreamPacketPayload(byteCount: 128),
                    streamID: 40,
                    frameNumber: UInt32(frameNumber),
                    sequenceNumberStart: UInt32(frameNumber * 10),
                    generation: generation,
                    sendDeadline: expiredDeadline
                )
            )
        }

        try await waitForStreamPacketSubmissionCount(submittedPackets, expectedCount: 2)

        #expect(submittedPackets.read { $0.map(\.frameNumber) } == [1, 2])
        #expect(dependencyDropCount.read { $0 == 1 })
        let localSnapshot = await sender.telemetrySnapshot
        #expect(localSnapshot.senderLocalDeadlineDrops == 1)
        #expect(localSnapshot.lateNonKeyframeSends == 2)
        #expect(localSnapshot.stalePacketDrops == 1)
        #expect(await sender.requiresDependencyRecoveryKeyframe())
        await sender.stop()
    }

    @Test("Keyframe submission clears non-keyframe hold before send completion")
    func keyframeSubmissionClearsHoldBeforeCompletion() async throws {
        let submittedPackets = Locked<[StreamPacketSenderSubmittedPacket]>([])
        let pendingCompletions = Locked<[StreamPacketSenderPendingSendCompletion]>([])
        let sender = StreamPacketSender(
            maxPayloadSize: 512,
            sendPacket: { packet, onComplete in
                guard let header = FrameHeader.deserialize(from: packet) else {
                    Issue.record("Failed to deserialize submitted packet")
                    onComplete(nil)
                    return
                }
                submittedPackets.withLock {
                    $0.append(StreamPacketSenderSubmittedPacket(frameNumber: header.frameNumber))
                }
                pendingCompletions.withLock { $0.append(StreamPacketSenderPendingSendCompletion(onComplete: onComplete)) }
            }
        )

        await sender.start()
        let generation = sender.currentGeneration
        sender.enqueue(
            makeStreamPacketWorkItem(
                payload: makeStreamPacketPayload(byteCount: 1024),
                streamID: 41,
                frameNumber: 70,
                sequenceNumberStart: 700,
                generation: generation,
                isKeyframe: true
            )
        )

        try await waitForStreamPacketSubmissionCount(submittedPackets, expectedCount: 2)

        sender.enqueue(
            makeStreamPacketWorkItem(
                payload: makeStreamPacketPayload(byteCount: 128),
                streamID: 41,
                frameNumber: 71,
                sequenceNumberStart: 800,
                generation: generation
            )
        )

        try await waitForStreamPacketSubmissionCount(submittedPackets, expectedCount: 3)

        let frameNumbers = submittedPackets.read { $0.map(\.frameNumber) }
        #expect(frameNumbers == [70, 70, 71])
        #expect(await (sender.telemetrySnapshot).nonKeyframeHoldDrops == 0)

        completePendingStreamPacketSends(pendingCompletions)
        try await waitForStreamPacketQueuedBytesToDrain(sender)
        await sender.stop()
    }

    @Test("Delayed keyframe completions do not drop following P-frames")
    func delayedKeyframeCompletionsDoNotDropFollowingPFrames() async throws {
        let submittedPackets = Locked<[StreamPacketSenderSubmittedPacket]>([])
        let pendingCompletions = Locked<[StreamPacketSenderPendingSendCompletion]>([])
        let sender = StreamPacketSender(
            maxPayloadSize: 512,
            sendPacket: { packet, onComplete in
                guard let header = FrameHeader.deserialize(from: packet) else {
                    Issue.record("Failed to deserialize submitted packet")
                    onComplete(nil)
                    return
                }
                submittedPackets.withLock {
                    $0.append(StreamPacketSenderSubmittedPacket(frameNumber: header.frameNumber))
                }
                pendingCompletions.withLock { $0.append(StreamPacketSenderPendingSendCompletion(onComplete: onComplete)) }
            }
        )

        await sender.start()
        let generation = sender.currentGeneration
        sender.enqueue(
            makeStreamPacketWorkItem(
                payload: makeStreamPacketPayload(byteCount: 1024),
                streamID: 42,
                frameNumber: 90,
                sequenceNumberStart: 900,
                generation: generation,
                isKeyframe: true
            )
        )
        for frameNumber in 91 ... 96 {
            sender.enqueue(
                makeStreamPacketWorkItem(
                    payload: makeStreamPacketPayload(byteCount: 128),
                    streamID: 42,
                    frameNumber: UInt32(frameNumber),
                    sequenceNumberStart: UInt32(frameNumber * 10),
                    generation: generation
                )
            )
        }

        try await waitForStreamPacketSubmissionCount(submittedPackets, expectedCount: 8)

        let frameNumbers = submittedPackets.read { $0.map(\.frameNumber) }
        #expect(frameNumbers == [90, 90, 91, 92, 93, 94, 95, 96])
        #expect(await (sender.telemetrySnapshot).nonKeyframeHoldDrops == 0)

        completePendingStreamPacketSends(pendingCompletions)
        try await waitForStreamPacketQueuedBytesToDrain(sender)
        await sender.stop()
    }

}

func waitForStreamPacketSubmissionCount(
    _ submittedPackets: Locked<[StreamPacketSenderSubmittedPacket]>,
    expectedCount: Int,
    timeout: Duration = .seconds(2)
) async throws {
    try await waitForStreamPacketCondition(timeout: timeout) { submittedPackets.read { $0.count } >= expectedCount }
    #expect(submittedPackets.read { $0.count } == expectedCount)
}

func waitForStreamPacketQueuedBytesToDrain(
    _ sender: StreamPacketSender,
    timeout: Duration = .seconds(2)
) async throws {
    try await waitForStreamPacketCondition(timeout: timeout) { sender.queuedByteCount == 0 }
    #expect(sender.queuedByteCount == 0)
}

func waitForStreamPacketTelemetry(
    _ sender: StreamPacketSender,
    timeout: Duration = .seconds(2),
    until predicate: @escaping (StreamPacketSender.TelemetrySnapshot) -> Bool
) async throws -> StreamPacketSender.TelemetrySnapshot {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        let snapshot = await sender.telemetrySnapshot
        if predicate(snapshot) {
            return snapshot
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    let snapshot = await sender.telemetrySnapshot
    Issue.record("Timed out waiting for telemetry condition")
    return snapshot
}

func waitForStreamPacketCondition(
    timeout: Duration = .seconds(2),
    pollInterval: Duration = .milliseconds(10),
    _ condition: () -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition(), ContinuousClock.now < deadline {
        try await Task.sleep(for: pollInterval)
    }
}

func completePendingStreamPacketSends(_ pendingCompletions: Locked<[StreamPacketSenderPendingSendCompletion]>) {
    pendingCompletions.withLock { completions in
        completions.forEach { $0.complete(nil) }
        completions.removeAll(keepingCapacity: false)
    }
}

func makeStreamPacketPayload(byteCount: Int) -> Data {
    Data((0 ..< byteCount).map { UInt8(truncatingIfNeeded: $0) })
}

func makeStreamPacketWorkItem(
    payload: Data,
    streamID: StreamID,
    frameNumber: UInt32,
    sequenceNumberStart: UInt32,
    generation: UInt32,
    isKeyframe: Bool = false,
    encodedAt: CFAbsoluteTime = CFAbsoluteTimeGetCurrent(),
    sendDeadline: CFAbsoluteTime? = nil,
    fecBlockSize: Int = 0
) -> StreamPacketSender.WorkItem {
    StreamPacketSender.WorkItem(
        encodedData: payload,
        frameByteCount: payload.count,
        isKeyframe: isKeyframe,
        presentationTime: CMTime(seconds: Double(frameNumber), preferredTimescale: 600),
        contentRect: CGRect(x: 0, y: 0, width: 100, height: 100),
        streamID: streamID,
        frameNumber: frameNumber,
        sequenceNumberStart: sequenceNumberStart,
        additionalFlags: [],
        dimensionToken: 0,
        epoch: 0,
        fecBlockSize: fecBlockSize,
        wireBytes: payload.count,
        logPrefix: "test",
        generation: generation,
        encodedAt: encodedAt,
        sendDeadline: sendDeadline,
        pacingOverride: nil
    )
}

struct StreamPacketSenderSubmittedPacket {
    let frameNumber: UInt32
}

struct StreamPacketSenderReliablePacketSummary: Equatable {
    let frameNumber: UInt32
    let sequenceNumber: UInt32
    let fragmentIndex: Int
    let fragmentCount: Int
    let fecBlockSize: Int
    let isFECParity: Bool
}

final class StreamPacketSenderPendingSendCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var onComplete: (@Sendable (Error?) -> Void)?

    init(onComplete: @escaping @Sendable (Error?) -> Void) {
        self.onComplete = onComplete
    }

    func complete(_ error: Error?) {
        lock.lock()
        let onComplete = onComplete
        self.onComplete = nil
        lock.unlock()
        onComplete?(error)
    }
}
#endif
