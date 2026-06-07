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
import Loom
import MirageKit
import Testing
import MirageCore
import MirageWire

@Suite("Stream Packet Sender Regression")
struct StreamPacketSenderRegressionTests {
    @Test("Unreliable keyframes duplicate parameter-set packet when enabled")
    func unreliableKeyframesDuplicateParameterSetPacketWhenEnabled() async throws {
        let sentHeaders = Locked<[MirageWire.FrameHeader]>([])
        let sender = StreamPacketSender(
            maxPayloadSize: 4,
            sendPacketWithMetadata: { packet, _, onComplete in
                guard let header = MirageWire.FrameHeader.deserialize(from: packet) else {
                    Issue.record("Failed to deserialize submitted packet")
                    onComplete(nil)
                    return
                }
                sentHeaders.withLock { $0.append(header) }
                onComplete(nil)
            },
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

    @Test("Parameter-set duplicates participate in packet pacing")
    func parameterSetDuplicatesParticipateInPacketPacing() async throws {
        let sentHeaders = Locked<[MirageWire.FrameHeader]>([])
        let sender = StreamPacketSender(
            maxPayloadSize: 1200,
            sendPacketWithMetadata: { packet, _, onComplete in
                guard let header = MirageWire.FrameHeader.deserialize(from: packet) else {
                    Issue.record("Failed to deserialize submitted packet")
                    onComplete(nil)
                    return
                }
                sentHeaders.withLock { $0.append(header) }
                onComplete(nil)
            },
            duplicatesParameterSetPackets: true
        )

        await sender.start()
        await sender.setTargetBitrateBps(8_000)
        let generation = sender.currentGeneration
        sender.enqueue(
            makeStreamPacketWorkItem(
                payload: makeStreamPacketPayload(byteCount: 1),
                streamID: 41,
                frameNumber: 13,
                sequenceNumberStart: 250,
                generation: generation,
                isKeyframe: true
            )
        )

        try await waitForStreamPacketCondition(timeout: .seconds(2)) {
            sentHeaders.read { $0.count } == 2
        }
        try await waitForStreamPacketQueuedBytesToDrain(sender)

        let headers = sentHeaders.read { $0 }
        let telemetry = await sender.telemetrySnapshot
        #expect(headers.map { Int($0.fragmentIndex) } == [0, 0])
        #expect(headers.map(\.sequenceNumber) == [250, 250])
        #expect(telemetry.packetPacerSleepTotalMs > StreamPacketSender.packetPacerMaxSleepMsPerPacket)

        await sender.stop()
    }

    @Test("Sender-local deadline-past P-frames still send")
    func senderLocalDeadlinePastPFramesStillSend() async throws {
        let submittedPackets = Locked<[StreamPacketSenderSubmittedPacket]>([])
        let dependencyDropCount = Locked(0)
        let sender = StreamPacketSender(
            maxPayloadSize: 512,
            sendPacketWithMetadata: { packet, _, onComplete in
                guard let header = MirageWire.FrameHeader.deserialize(from: packet) else {
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
            sendPacketWithMetadata: { packet, _, onComplete in
                guard let header = MirageWire.FrameHeader.deserialize(from: packet) else {
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
            sendPacketWithMetadata: { packet, _, onComplete in
                guard let header = MirageWire.FrameHeader.deserialize(from: packet) else {
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
            sendPacketWithMetadata: { packet, _, onComplete in
                guard let header = MirageWire.FrameHeader.deserialize(from: packet) else {
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

    @Test("Queued unreliable media drops are nonfatal transport drops")
    func queuedUnreliableMediaDropsAreNonfatalTransportDrops() async throws {
        let sendErrorCount = Locked(0)
        let completions = Locked<[StreamPacketSender.FrameTransportCompletion]>([])
        let dropReasons: [LoomQueuedUnreliableSendDrop.Reason] = [
            .deadlineExpired,
            .queueLimit,
            .superseded,
            .unsupportedTransport,
            .closed,
        ]
        let sender = StreamPacketSender(
            maxPayloadSize: 4,
            sendPacketWithMetadata: { _, metadata, onComplete in
                onComplete(LoomQueuedUnreliableSendDrop(
                    reason: dropReasons[metadata.fragmentIndex],
                    profile: .proximityRealtimeDisplay,
                    frameID: UInt64(metadata.frameNumber),
                    fragmentIndex: metadata.fragmentIndex,
                    fragmentCount: metadata.fragmentCount
                ))
            },
            onSendError: { _ in
                sendErrorCount.withLock { $0 += 1 }
            },
            onFrameTransportCompleted: { completion in
                completions.withLock { $0.append(completion) }
            }
        )

        await sender.start()
        let generation = sender.currentGeneration
        sender.enqueue(
            makeStreamPacketWorkItem(
                payload: makeStreamPacketPayload(byteCount: 20),
                streamID: 42,
                frameNumber: 77,
                sequenceNumberStart: 770,
                generation: generation,
                sendDeadline: CFAbsoluteTimeGetCurrent() + 0.01
            )
        )

        try await waitForStreamPacketCondition(timeout: .seconds(2)) {
            completions.read { !$0.isEmpty }
        }
        try await waitForStreamPacketQueuedBytesToDrain(sender)

        #expect(sendErrorCount.read { $0 } == 0)
        let completion = completions.read { $0.first }
        #expect(completion?.frameNumber == 77)
        #expect(completion?.didSend == false)
        let telemetry = await sender.telemetrySnapshot
        #expect(telemetry.queuedUnreliableDeadlineExpiredDrops == 1)
        #expect(telemetry.queuedUnreliableQueueLimitDrops == 1)
        #expect(telemetry.queuedUnreliableSupersededDrops == 1)
        #expect(telemetry.queuedUnreliableUnsupportedTransportDrops == 1)
        #expect(telemetry.queuedUnreliableClosedDrops == 1)

        await sender.stop()
    }

    @Test("Transport data drop starts dependency repair before sibling fragments complete")
    func transportDataDropStartsDependencyRepairBeforeSiblingFragmentsComplete() async throws {
        let submittedHeaders = Locked<[MirageWire.FrameHeader]>([])
        let pendingCompletions = Locked<[StreamPacketSenderPendingSendCompletion]>([])
        let dependencyDrops = Locked<[(frameNumber: UInt32, reason: StreamPacketSender.DependencyFrameDropReason)]>([])
        let sender = StreamPacketSender(
            maxPayloadSize: 4,
            sendPacketWithMetadata: { packet, metadata, onComplete in
                guard let header = MirageWire.FrameHeader.deserialize(from: packet) else {
                    Issue.record("Failed to deserialize submitted packet")
                    onComplete(nil)
                    return
                }
                submittedHeaders.withLock { $0.append(header) }
                if header.frameNumber == 77, header.fragmentIndex == 0 {
                    onComplete(LoomQueuedUnreliableSendDrop(
                        reason: .deadlineExpired,
                        profile: .interactiveMedia,
                        frameID: UInt64(header.frameNumber),
                        fragmentIndex: metadata.fragmentIndex,
                        fragmentCount: metadata.fragmentCount
                    ))
                } else {
                    pendingCompletions.withLock {
                        $0.append(StreamPacketSenderPendingSendCompletion(onComplete: onComplete))
                    }
                }
            },
            onDependencyFrameDropped: { _, frameNumber, reason in
                dependencyDrops.withLock { $0.append((frameNumber, reason)) }
            }
        )

        await sender.start()
        let generation = sender.currentGeneration
        sender.enqueue(
            makeStreamPacketWorkItem(
                payload: makeStreamPacketPayload(byteCount: 20),
                streamID: 42,
                frameNumber: 77,
                sequenceNumberStart: 770,
                generation: generation,
                sendDeadline: CFAbsoluteTimeGetCurrent() + 0.5
            )
        )

        try await waitForStreamPacketCondition(timeout: .seconds(2)) {
            dependencyDrops.read { !$0.isEmpty }
        }

        #expect(dependencyDrops.read { $0.first?.frameNumber } == 77)
        #expect(dependencyDrops.read { $0.first?.reason } == .transportDrop)
        #expect(await sender.requiresDependencyRecoveryKeyframe())

        sender.enqueue(
            makeStreamPacketWorkItem(
                payload: makeStreamPacketPayload(byteCount: 4),
                streamID: 42,
                frameNumber: 78,
                sequenceNumberStart: 780,
                generation: generation,
                sendDeadline: CFAbsoluteTimeGetCurrent() + 0.5
            )
        )

        let telemetry = try await waitForStreamPacketTelemetry(sender) {
            $0.nonKeyframeHoldDrops >= 1
        }
        #expect(telemetry.nonKeyframeHoldDrops >= 1)
        #expect(submittedHeaders.read { !$0.contains(where: { $0.frameNumber == 78 }) })

        completePendingStreamPacketSends(pendingCompletions)
        try await waitForStreamPacketQueuedBytesToDrain(sender)
        await sender.stop()
    }

    @Test("AWDL P-frame metadata uses hard playout deadline")
    func awdlPFrameMetadataUsesHardPlayoutDeadline() async throws {
        let sentMetadata = Locked<[StreamPacketSender.TransportPacketMetadata]>([])
        let sender = StreamPacketSender(
            maxPayloadSize: 512,
            sendPacketWithMetadata: { _, metadata, onComplete in
                sentMetadata.withLock { $0.append(metadata) }
                onComplete(nil)
            }
        )

        await sender.start()
        let generation = sender.currentGeneration
        let sendDeadline = CFAbsoluteTimeGetCurrent() + 0.050
        let hardSendDeadline = sendDeadline + 0.180
        sender.enqueue(
            makeStreamPacketWorkItem(
                payload: makeStreamPacketPayload(byteCount: 128),
                streamID: 42,
                frameNumber: 79,
                sequenceNumberStart: 790,
                generation: generation,
                sendDeadline: sendDeadline,
                hardSendDeadline: hardSendDeadline,
                usesAwdlRealtimeQueuePolicy: true
            )
        )

        try await waitForStreamPacketCondition(timeout: .seconds(2)) {
            !sentMetadata.read { $0.isEmpty }
        }

        let metadata = try #require(sentMetadata.read { $0.first })
        #expect(metadata.sendDeadline == hardSendDeadline)
        try await waitForStreamPacketQueuedBytesToDrain(sender)
        await sender.stop()
    }

    @Test("AWDL keyframe metadata uses recovery pacing deadline")
    func awdlKeyframeMetadataUsesRecoveryPacingDeadline() async throws {
        let sentMetadata = Locked<[StreamPacketSender.TransportPacketMetadata]>([])
        let sender = StreamPacketSender(
            maxPayloadSize: 512,
            sendPacketWithMetadata: { _, metadata, onComplete in
                sentMetadata.withLock { $0.append(metadata) }
                onComplete(nil)
            }
        )

        await sender.start()
        let generation = sender.currentGeneration
        let sendDeadline = CFAbsoluteTimeGetCurrent() + 0.025
        let recoveryPacingDeadline = sendDeadline + 0.160
        sender.enqueue(
            makeStreamPacketWorkItem(
                payload: makeStreamPacketPayload(byteCount: 128),
                streamID: 42,
                frameNumber: 80,
                sequenceNumberStart: 800,
                generation: generation,
                isKeyframe: true,
                sendDeadline: sendDeadline,
                hardSendDeadline: recoveryPacingDeadline,
                usesAwdlRealtimeQueuePolicy: true
            )
        )

        try await waitForStreamPacketCondition(timeout: .seconds(2)) {
            !sentMetadata.read { $0.isEmpty }
        }

        let metadata = try #require(sentMetadata.read { $0.first })
        #expect(metadata.isKeyframe)
        #expect(metadata.sendDeadline == recoveryPacingDeadline)
        try await waitForStreamPacketQueuedBytesToDrain(sender)
        await sender.stop()
    }

    @Test("AWDL realtime sender sheds queued P-frames before Loom admission")
    func awdlRealtimeSenderShedsQueuedPFramesBeforeLoomAdmission() async throws {
        let pendingCompletions = Locked<[StreamPacketSenderPendingSendCompletion]>([])
        let sender = StreamPacketSender(
            maxPayloadSize: 512,
            sendPacketWithMetadata: { _, _, onComplete in
                pendingCompletions.withLock {
                    $0.append(StreamPacketSenderPendingSendCompletion(onComplete: onComplete))
                }
            }
        )

        await sender.start()
        let generation = sender.currentGeneration
        sender.enqueue(
            makeStreamPacketWorkItem(
                payload: makeStreamPacketPayload(byteCount: 64 * 1024),
                streamID: 42,
                frameNumber: 80,
                sequenceNumberStart: 800,
                generation: generation,
                isKeyframe: true,
                pacingOverride: StreamPacketSender.PacingOverride(rateBps: 1_000, burstBytes: 1),
                usesAwdlRealtimeQueuePolicy: true
            )
        )

        let now = CFAbsoluteTimeGetCurrent()
        for frameNumber in 81 ... 88 {
            sender.enqueue(
                makeStreamPacketWorkItem(
                    payload: makeStreamPacketPayload(byteCount: 16 * 1024),
                    streamID: 42,
                    frameNumber: UInt32(frameNumber),
                    sequenceNumberStart: UInt32(frameNumber * 10),
                    generation: generation,
                    sendDeadline: now + 0.050,
                    hardSendDeadline: now + 0.200,
                    usesAwdlRealtimeQueuePolicy: true
                )
            )
        }

        let telemetry = try await waitForStreamPacketTelemetry(sender) {
            $0.stalePacketDrops + $0.nonKeyframeHoldDrops >= 6
        }
        #expect(telemetry.unstartedPFrameCount <= StreamPacketSender.maxAwdlQueuedNonKeyframes)
        #expect(telemetry.stalePacketDrops + telemetry.nonKeyframeHoldDrops >= 6)
        #expect(await sender.requiresDependencyRecoveryKeyframe())

        await sender.stop()
        completePendingStreamPacketSends(pendingCompletions)
    }

    @Test("Queued unreliable parity drops do not fail completed data frames")
    func queuedUnreliableParityDropsDoNotFailCompletedDataFrames() async throws {
        let completions = Locked<[StreamPacketSender.FrameTransportCompletion]>([])
        let sender = StreamPacketSender(
            maxPayloadSize: 4,
            sendPacketWithMetadata: { _, metadata, onComplete in
                if metadata.isParity {
                    onComplete(LoomQueuedUnreliableSendDrop(
                        reason: .deadlineExpired,
                        profile: .proximityRealtimeDisplay,
                        frameID: UInt64(metadata.frameNumber),
                        fragmentIndex: metadata.fragmentIndex,
                        fragmentCount: metadata.fragmentCount
                    ))
                } else {
                    onComplete(nil)
                }
            },
            onFrameTransportCompleted: { completion in
                completions.withLock { $0.append(completion) }
            }
        )

        await sender.start()
        let generation = sender.currentGeneration
        sender.enqueue(
            makeStreamPacketWorkItem(
                payload: makeStreamPacketPayload(byteCount: 10),
                streamID: 42,
                frameNumber: 78,
                sequenceNumberStart: 780,
                generation: generation,
                sendDeadline: CFAbsoluteTimeGetCurrent() + 0.05,
                fecBlockSize: 2
            )
        )

        try await waitForStreamPacketCondition(timeout: .seconds(2)) {
            completions.read { !$0.isEmpty }
        }
        try await waitForStreamPacketQueuedBytesToDrain(sender)

        let completion = completions.read { $0.first }
        #expect(completion?.frameNumber == 78)
        #expect(completion?.didSend == true)
        let telemetry = await sender.telemetrySnapshot
        #expect(telemetry.queuedUnreliableDeadlineExpiredDrops == 2)
        #expect(telemetry.queuedUnreliableQueueLimitDrops == 0)
        #expect(telemetry.queuedUnreliableSupersededDrops == 0)
        #expect(telemetry.queuedUnreliableUnsupportedTransportDrops == 0)
        #expect(telemetry.queuedUnreliableClosedDrops == 0)

        await sender.stop()
    }

    @Test("Queued unreliable metadata converts sender deadlines to Mirage uptime")
    func queuedUnreliableMetadataConvertsSenderDeadlinesToMirageUptime() {
        let sendDeadline = CFAbsoluteTimeGetCurrent() + 0.250
        let expectedFrameID = (UInt64(42) << 32) | UInt64(880)
        let options = StreamPacketSender.TransportPacketMetadata(
            streamID: 42,
            frameNumber: 880,
            fragmentIndex: 1,
            fragmentCount: 4,
            isKeyframe: false,
            isParity: false,
            isRecovery: false,
            sendDeadline: sendDeadline
        ).mirageQueuedUnreliableSendOptions

        let remainingMs = ((options.deadlineUptime ?? 0) - ProcessInfo.processInfo.systemUptime) * 1000
        #expect(options.importance == .realtimeInterFrame)
        #expect(options.frameID == expectedFrameID)
        #expect(options.fragmentIndex == 1)
        #expect(options.fragmentCount == 4)
        #expect(options.dropsWhenExpired)
        #expect(options.dropsWhenQueueFull)
        #expect(remainingMs > 0)
        #expect(remainingMs < 500)
    }

    @Test("FEC-protected P-frame metadata maps to recovery importance")
    func fecProtectedPFrameMetadataMapsToRecoveryImportance() {
        let expectedFrameID = (UInt64(42) << 32) | UInt64(881)
        let options = StreamPacketSender.TransportPacketMetadata(
            streamID: 42,
            frameNumber: 881,
            fragmentIndex: 0,
            fragmentCount: 6,
            isKeyframe: false,
            isParity: false,
            isRecovery: true,
            sendDeadline: CFAbsoluteTimeGetCurrent() + 0.250
        ).mirageQueuedUnreliableSendOptions

        #expect(options.importance == .realtimeRecovery)
        #expect(options.frameID == expectedFrameID)
        #expect(options.dropsWhenExpired)
        #expect(!options.dropsWhenQueueFull)
    }

    @Test("Queued unreliable metadata scopes frame groups by Mirage stream")
    func queuedUnreliableMetadataScopesFrameGroupsByMirageStream() {
        let firstOptions = StreamPacketSender.TransportPacketMetadata(
            streamID: 42,
            frameNumber: 881,
            fragmentIndex: 0,
            fragmentCount: 6,
            isKeyframe: false,
            isParity: false,
            isRecovery: false,
            sendDeadline: CFAbsoluteTimeGetCurrent() + 0.250
        ).mirageQueuedUnreliableSendOptions
        let secondOptions = StreamPacketSender.TransportPacketMetadata(
            streamID: 43,
            frameNumber: 881,
            fragmentIndex: 0,
            fragmentCount: 6,
            isKeyframe: false,
            isParity: false,
            isRecovery: false,
            sendDeadline: CFAbsoluteTimeGetCurrent() + 0.250
        ).mirageQueuedUnreliableSendOptions

        #expect(firstOptions.frameID != secondOptions.frameID)
        #expect(firstOptions.frameID == ((UInt64(42) << 32) | UInt64(881)))
        #expect(secondOptions.frameID == ((UInt64(43) << 32) | UInt64(881)))
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
    hardSendDeadline: CFAbsoluteTime? = nil,
    fecBlockSize: Int = 0,
    pacingOverride: StreamPacketSender.PacingOverride? = nil,
    usesAwdlRealtimeQueuePolicy: Bool = false
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
        hardSendDeadline: hardSendDeadline,
        pacingOverride: pacingOverride,
        usesAwdlRealtimeQueuePolicy: usesAwdlRealtimeQueuePolicy
    )
}

struct StreamPacketSenderSubmittedPacket {
    let frameNumber: UInt32
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
