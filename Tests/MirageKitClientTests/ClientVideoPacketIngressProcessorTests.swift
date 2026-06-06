//
//  ClientVideoPacketIngressProcessorTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/10/26.
//

@testable import MirageKitClient
import Foundation
import Loom
@testable import MirageKit
import Testing

@Suite("Client Video Packet Ingress Processor", .serialized)
struct ClientVideoPacketIngressProcessorTests {
    @Test("Direct ingress snapshot includes silent open interval")
    func directIngressSnapshotIncludesSilentOpenInterval() {
        let recorder = ClientVideoDirectIngressTelemetryRecorder()

        _ = recorder.recordPacket(now: 100)
        let snapshot = recorder.snapshot(now: 100.25)

        #expect(snapshot.incomingBatchIntervalP95Ms >= 250)
        #expect(snapshot.incomingBatchIntervalP99Ms >= 250)
        #expect(snapshot.incomingBatchIntervalMaxMs >= 250)
    }

    @Test("Processor drains enqueued batches in order")
    func processorDrainsEnqueuedBatchesInOrder() async throws {
        let collector = PacketProcessingGate()
        let processor = ClientVideoPacketIngressProcessor(streamID: 42) { data, streamID in
            collector.record(data, streamID: streamID)
        }
        defer { processor.finish() }

        let expected = (0 ..< 5).map { Data([$0]) }
        processor.enqueue(Array(expected[0 ..< 2]))
        processor.enqueue(Array(expected[2 ..< 5]))

        let received = try #require(
            await collector.payloads(target: expected.count, timeoutSeconds: 1.0)
        )
        #expect(received.map(\.data) == expected)
        #expect(received.map(\.streamID) == Array(repeating: 42, count: expected.count))

        let snapshot = processor.snapshot()
        #expect(snapshot.processedPacketCount == UInt64(expected.count))
        #expect(snapshot.loomStreamDeliveryPPS >= Double(expected.count))
        #expect(snapshot.loomStreamDeliveryIntervalMaxMs >= 0)
        #expect(snapshot.rawPacketIngressPPS >= Double(expected.count))
        #expect(snapshot.incomingBatchRate >= 2)
        #expect(snapshot.incomingBatchMaxSize == 3)
        #expect(snapshot.stalePacketDropCount == 0)
        #expect(snapshot.overloadPacketDropCount == 0)
        #expect(snapshot.processorWakeDelayMaxMs < 100)
    }

    @Test("Processor trims overload without age-based packet drops")
    func processorTrimsOverloadWithoutAgeBasedPacketDrops() async throws {
        let gate = PacketProcessingGate()
        let processor = ClientVideoPacketIngressProcessor(
            streamID: 7,
            maxQueuedBatches: 2,
            maxQueuedPackets: 2
        ) { data, streamID in
            gate.record(data, streamID: streamID)
        }
        defer {
            gate.unblock()
            processor.finish()
        }

        gate.block()
        processor.enqueue([Data([0])])
        try await Task.sleep(for: .milliseconds(5))
        var snapshot = processor.snapshot()
        #expect(snapshot.stalePacketDropCount == 0)

        processor.enqueue([Data([2])])
        processor.enqueue([Data([3])])
        processor.enqueue([Data([4])])
        processor.enqueue([Data([5])])

        snapshot = processor.snapshot()
        #expect(snapshot.stalePacketDropCount == 0)
        #expect(snapshot.overloadPacketDropCount > 0)
        #expect(snapshot.queuedPacketCount <= 2)

        gate.unblock()
        _ = await gate.payloads(timeoutSeconds: 1.0)
        snapshot = processor.snapshot()
        #expect(snapshot.queueAgeMaxMs >= 0)
    }

    @Test("Processor trims stale non-recovery packets")
    func processorTrimsStaleNonRecoveryPackets() async throws {
        let gate = PacketProcessingGate()
        let processor = ClientVideoPacketIngressProcessor(
            streamID: 7,
            maxQueuedBatches: 8,
            maxQueuedPackets: 64,
            staleNonRecoveryPacketAge: 0.025
        ) { data, streamID in
            gate.record(data, streamID: streamID)
        }
        defer {
            gate.unblock()
            processor.finish()
        }

        let blocker = Data([0])
        let stalePFrame = makeVideoPacket(streamID: 7, frameNumber: 1, flags: [])
        let keyframe = makeVideoPacket(streamID: 7, frameNumber: 2, flags: [.keyframe])

        gate.block()
        processor.enqueue([blocker])
        try #require(await gate.startedPayloads(containing: blocker, timeoutSeconds: 1.0).contains {
            $0.data == blocker
        })
        processor.enqueue([stalePFrame])
        try await Task.sleep(for: .milliseconds(50))
        processor.enqueue([keyframe])

        let snapshot = processor.snapshot()
        #expect(snapshot.stalePacketDropCount == 1)
        #expect(snapshot.overloadPacketDropCount == 0)

        gate.unblock()
        let received = await gate.payloads(containing: keyframe, timeoutSeconds: 1.0)
        #expect(received.map(\.data).contains(keyframe))
        #expect(!received.map(\.data).contains(stalePFrame))
    }

    @Test("Processor default stale window covers AWDL playout recovery")
    func processorDefaultStaleWindowCoversAwdlPlayoutRecovery() async throws {
        #expect(
            ClientVideoPacketIngressProcessor.defaultStaleNonRecoveryPacketAge >=
                MirageAwdlMediaController.maximumPlayoutDelayMs / 1000 + 0.250
        )

        let gate = PacketProcessingGate()
        let processor = ClientVideoPacketIngressProcessor(
            streamID: 7,
            maxQueuedBatches: 8,
            maxQueuedPackets: 64
        ) { data, streamID in
            gate.record(data, streamID: streamID)
        }
        defer {
            gate.unblock()
            processor.finish()
        }

        let blocker = Data([0])
        let pFrame = makeVideoPacket(streamID: 7, frameNumber: 3, flags: [])
        let keyframe = makeVideoPacket(streamID: 7, frameNumber: 4, flags: [.keyframe])

        gate.block()
        processor.enqueue([blocker])
        try #require(await gate.startedPayloads(containing: blocker, timeoutSeconds: 1.0).contains {
            $0.data == blocker
        })
        processor.enqueue([pFrame])
        try await Task.sleep(for: .milliseconds(320))
        processor.enqueue([keyframe])

        let snapshot = processor.snapshot()
        #expect(snapshot.stalePacketDropCount == 0)
        #expect(snapshot.queuedPacketCount == 2)

        gate.unblock()
        let received = try #require(await gate.payloads(target: 3, timeoutSeconds: 1.0))
        let receivedPayloads = received.map(\.data)
        #expect(receivedPayloads.contains(pFrame))
        #expect(receivedPayloads.contains(keyframe))
    }

    @Test("Processor preserves stale recovery packets while trimming stale P-frames")
    func processorPreservesStaleRecoveryPacketsWhileTrimmingStalePFrames() async throws {
        let gate = PacketProcessingGate()
        let processor = ClientVideoPacketIngressProcessor(
            streamID: 7,
            maxQueuedBatches: 8,
            maxQueuedPackets: 64,
            staleNonRecoveryPacketAge: 0.025
        ) { data, streamID in
            gate.record(data, streamID: streamID)
        }
        defer {
            gate.unblock()
            processor.finish()
        }

        let blocker = Data([0])
        let stalePFrame = makeVideoPacket(streamID: 7, frameNumber: 10, flags: [])
        let keyframe = makeVideoPacket(streamID: 7, frameNumber: 11, flags: [.keyframe])
        let parameterSet = makeVideoPacket(streamID: 7, frameNumber: 12, flags: [.parameterSet])
        let discontinuity = makeVideoPacket(streamID: 7, frameNumber: 13, flags: [.discontinuity])
        let priority = makeVideoPacket(streamID: 7, frameNumber: 14, flags: [.priority])
        let fecParity = makeVideoPacket(streamID: 7, frameNumber: 15, flags: [.fecParity])
        let fecProtectedPFrame = makeVideoPacket(streamID: 7, frameNumber: 16, flags: [], fecBlockSize: 4)
        let recoveryPackets = [keyframe, parameterSet, discontinuity, priority, fecParity, fecProtectedPFrame]

        gate.block()
        processor.enqueue([blocker])
        try #require(await gate.startedPayloads(containing: blocker, timeoutSeconds: 1.0).contains {
            $0.data == blocker
        })
        processor.enqueue([stalePFrame] + recoveryPackets)
        try await Task.sleep(for: .milliseconds(50))

        let snapshot = processor.snapshot()
        #expect(snapshot.stalePacketDropCount == 1)
        #expect(snapshot.queuedPacketCount == recoveryPackets.count)

        gate.unblock()
        let received = await gate.payloads(target: recoveryPackets.count + 1, timeoutSeconds: 1.0) ?? []
        let receivedPayloads = received.map(\.data)
        #expect(!receivedPayloads.contains(stalePFrame))
        for packet in recoveryPackets {
            #expect(receivedPayloads.contains(packet))
        }
    }

    @Test("Processor only hard-drops under explicit overload")
    func processorOnlyHardDropsUnderExplicitOverload() async throws {
        let gate = PacketProcessingGate()
        let processor = ClientVideoPacketIngressProcessor(
            streamID: 7,
            maxQueuedBatches: 2,
            maxQueuedPackets: 2
        ) { data, streamID in
            gate.record(data, streamID: streamID)
        }
        defer {
            gate.unblock()
            processor.finish()
        }

        let blocker = Data([0])
        let pFrame = makeVideoPacket(streamID: 7, frameNumber: 1, flags: [])
        let keyframe = makeVideoPacket(streamID: 7, frameNumber: 2, flags: [.keyframe])
        let laterPFrame = makeVideoPacket(streamID: 7, frameNumber: 3, flags: [])

        gate.block()
        processor.enqueue([blocker])
        processor.enqueue([pFrame])
        processor.enqueue([keyframe])
        processor.enqueue([laterPFrame])

        let snapshot = processor.snapshot()
        #expect(snapshot.stalePacketDropCount == 0)
        #expect(snapshot.overloadPacketDropCount > 0)

        gate.unblock()
        let received = await gate.payloads(containing: keyframe, timeoutSeconds: 1.0)
        #expect(received.map(\.data).contains(keyframe))
    }

    @Test("Processor overload trims mixed batches by packet importance")
    func processorOverloadTrimsMixedBatchesByPacketImportance() async throws {
        let gate = PacketProcessingGate()
        let processor = ClientVideoPacketIngressProcessor(
            streamID: 7,
            maxQueuedBatches: 8,
            maxQueuedPackets: 2
        ) { data, streamID in
            gate.record(data, streamID: streamID)
        }
        defer {
            gate.unblock()
            processor.finish()
        }

        let blocker = Data([0])
        let pFrame = makeVideoPacket(streamID: 7, frameNumber: 20, flags: [])
        let keyframe = makeVideoPacket(streamID: 7, frameNumber: 21, flags: [.keyframe])
        let fecParity = makeVideoPacket(streamID: 7, frameNumber: 22, flags: [.fecParity])

        gate.block()
        processor.enqueue([blocker])
        try #require(await gate.startedPayloads(containing: blocker, timeoutSeconds: 1.0).contains {
            $0.data == blocker
        })
        processor.enqueue([pFrame, keyframe])
        processor.enqueue([fecParity])

        let snapshot = processor.snapshot()
        #expect(snapshot.overloadPacketDropCount == 1)
        #expect(snapshot.protectedOverloadPacketDropCount == 0)
        #expect(snapshot.queuedPacketCount == 2)

        gate.unblock()
        let received = try #require(await gate.payloads(target: 3, timeoutSeconds: 1.0))
        let receivedPayloads = received.map(\.data)
        #expect(!receivedPayloads.contains(pFrame))
        #expect(receivedPayloads.contains(keyframe))
        #expect(receivedPayloads.contains(fecParity))
    }

    @Test("Processor records protected hard drops only when every queued packet is protected")
    func processorRecordsProtectedHardDropsOnlyWhenEveryQueuedPacketIsProtected() async throws {
        let gate = PacketProcessingGate()
        let processor = ClientVideoPacketIngressProcessor(
            streamID: 7,
            maxQueuedBatches: 8,
            maxQueuedPackets: 2
        ) { data, streamID in
            gate.record(data, streamID: streamID)
        }
        defer {
            gate.unblock()
            processor.finish()
        }

        let blocker = Data([0])
        let keyframe = makeVideoPacket(streamID: 7, frameNumber: 30, flags: [.keyframe])
        let parameterSet = makeVideoPacket(streamID: 7, frameNumber: 31, flags: [.parameterSet])
        let fecProtectedPFrame = makeVideoPacket(streamID: 7, frameNumber: 32, flags: [], fecBlockSize: 4)
        let protectedPackets = [keyframe, parameterSet, fecProtectedPFrame]

        gate.block()
        processor.enqueue([blocker])
        try #require(await gate.startedPayloads(containing: blocker, timeoutSeconds: 1.0).contains {
            $0.data == blocker
        })
        for packet in protectedPackets {
            processor.enqueue([packet])
        }

        let snapshot = processor.snapshot()
        #expect(snapshot.overloadPacketDropCount == 1)
        #expect(snapshot.protectedOverloadPacketDropCount == 1)
        #expect(snapshot.queuedPacketCount == 2)

        gate.unblock()
        let received = try #require(await gate.payloads(target: 3, timeoutSeconds: 1.0))
        let receivedPayloads = received.map(\.data)
        let deliveredProtectedCount = protectedPackets.filter { receivedPayloads.contains($0) }.count
        #expect(deliveredProtectedCount == 2)
    }

    @MainActor
    @Test("Video stream listener defaults to direct incoming bytes")
    func videoStreamListenerDefaultsToDirectIncomingBytes() async throws {
        UserDefaults.standard.removeObject(forKey: "MirageVideoIngressMode")
        let pair = try await makeLoopbackControlPair()
        try await pair.startAuthenticatedSessions()
        let service = MirageClientService(deviceName: "Client Ingress Test")
        service.loomSession = pair.client
        service.startMediaStreamListener()

        let videoStream = try await pair.server.openStream(label: "video/77")
        do {
            for index in 0 ..< 3 {
                try await videoStream.sendUnreliable(Data([UInt8(index)]))
            }

            let snapshot = try #require(await waitForIngressSnapshot(service: service, streamID: 77, count: 3))
            #expect(service.videoPacketIngressProcessors[77] == nil)
            #expect(snapshot.processedPacketCount >= 3)

            service.stopMediaStreamListener()
            #expect(service.videoPacketIngressProcessors[77] == nil)
            #expect(service.activeMediaStreams["video/77"] == nil)
            try? await videoStream.close()
            await pair.stop()
        } catch {
            service.stopMediaStreamListener()
            try? await videoStream.close()
            await pair.stop()
            throw error
        }
    }

    @MainActor
    @Test("Video stream listener keeps processor mode selectable")
    func videoStreamListenerKeepsProcessorModeSelectable() async throws {
        UserDefaults.standard.set("processor", forKey: "MirageVideoIngressMode")
        defer {
            UserDefaults.standard.removeObject(forKey: "MirageVideoIngressMode")
        }

        let pair = try await makeLoopbackControlPair()
        try await pair.startAuthenticatedSessions()
        let service = MirageClientService(deviceName: "Client Ingress Test")
        service.loomSession = pair.client
        service.startMediaStreamListener()

        let videoStream = try await pair.server.openStream(label: "video/78")
        do {
            let processor = try #require(await waitForProcessor(service: service, streamID: 78))
            for index in 0 ..< 3 {
                try await videoStream.sendUnreliable(Data([UInt8(index)]))
            }

            try #require(await waitForProcessedPackets(processor: processor, count: 3))
            let snapshot = processor.snapshot()
            #expect(snapshot.incomingBatchMaxSize == 1)
            #expect(snapshot.processedPacketCount >= 3)

            service.stopMediaStreamListener()
            #expect(service.videoPacketIngressProcessors[78] == nil)
            #expect(service.activeMediaStreams["video/78"] == nil)
            try? await videoStream.close()
            await pair.stop()
        } catch {
            service.stopMediaStreamListener()
            try? await videoStream.close()
            await pair.stop()
            throw error
        }
    }
}
