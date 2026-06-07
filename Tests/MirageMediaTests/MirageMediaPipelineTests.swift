//
//  MirageMediaPipelineTests.swift
//  MirageMedia
//
//  Created by Ethan Lipnik on 6/5/26.
//

import Foundation
import MirageCore
import MirageMedia
import Testing

@Suite("MirageMedia Pipeline")
struct MirageMediaPipelineTests {
    @Test("Encoded media units and packetizer input preserve topology scope")
    func encodedMediaUnitsAndPacketizerInputPreserveTopologyScope() throws {
        let topologyID = try MirageMediaTopologyID(
            rawValue: #require(UUID(uuidString: "9674B5F9-8346-4410-B194-3E633EAB449C"))
        )
        let unit = MirageEncodedMediaUnit(
            streamID: 7,
            topologyID: topologyID,
            mediaUnitID: .primary,
            unitFrameNumber: 42,
            presentationTime: MiragePresentationTime(seconds: 1.25),
            dependency: .keyframe,
            payload: Data([0x01, 0x02, 0x03])
        )
        let mismatchedUnit = MirageEncodedMediaUnit(
            streamID: 99,
            topologyID: topologyID,
            mediaUnitID: MirageMediaUnitID(rawValue: "other"),
            unitFrameNumber: 43,
            presentationTime: MiragePresentationTime(seconds: 1.30),
            dependency: .predicted,
            payload: Data([0x04])
        )
        let batch = MirageEncodedMediaBatch(streamID: 7, topologyID: topologyID, units: [unit, mismatchedUnit])
        let packetizerInput = MiragePacketizerInput(unit: unit, maximumPayloadBytes: 0)

        #expect(batch.units == [unit])
        #expect(!batch.isEmpty)
        #expect(packetizerInput.maximumPayloadBytes == 1)
        #expect(packetizerInput.payloadByteCount == 3)

        let encoded = try JSONEncoder().encode(unit)
        let decoded = try JSONDecoder().decode(MirageEncodedMediaUnit.self, from: encoded)
        let json = try #require(String(data: encoded, encoding: .utf8))

        #expect(decoded == unit)
        #expect(json.contains("\"keyframe\""))
        #expect(json.contains("\"primary\""))
    }

    @Test("Recovery scopes and decode budgets normalize media policy")
    func recoveryScopesAndDecodeBudgetsNormalizeMediaPolicy() throws {
        let topologyID = try MirageMediaTopologyID(
            rawValue: #require(UUID(uuidString: "CC53F2F1-2BBE-47D3-A48E-F4926E2D7111"))
        )
        let fullStream = MirageRecoveryScope.fullStream(3)
        let unitScope = MirageRecoveryScope(
            streamID: 3,
            topologyID: topologyID,
            mediaUnitID: MirageMediaUnitID(rawValue: "region-a")
        )
        let request = MirageRecoveryRequest(scope: unitScope, cause: .presentationStall)
        let policy = MirageDecodeBudgetPolicy(maximumQueuedFrames: 0, maximumInFlightSubmissions: -1)

        #expect(!fullStream.isUnitScoped)
        #expect(unitScope.isUnitScoped)
        #expect(request.cause == .presentationStall)
        #expect(policy.maximumQueuedFrames == 1)
        #expect(policy.maximumInFlightSubmissions == 1)
        #expect(MirageRecoveryCause.allCases == [.startup, .keyframeLoss, .presentationStall, .resize, .manual])
    }

    @Test("Pipeline protocols support topology-scoped host client and compositor fakes")
    func pipelineProtocolsSupportTopologyScopedFakes() async throws {
        let topologyID = try MirageMediaTopologyID(
            rawValue: #require(UUID(uuidString: "ACF8D5B5-7509-4708-81D1-2E7D0F88E0AA"))
        )
        let topology = MirageMediaTopology.singleUnit(
            id: topologyID,
            logicalSize: MiragePixelSize(width: 1280, height: 720),
            codec: .hevc
        )
        let unit = MirageEncodedMediaUnit(
            streamID: 11,
            topologyID: topologyID,
            mediaUnitID: .primary,
            unitFrameNumber: 1,
            presentationTime: MiragePresentationTime(seconds: 0.5),
            dependency: .keyframe,
            payload: Data([0xAA])
        )

        let host = FakeHostMediaPipeline()
        try await host.start()
        await host.submit(FakeCapturedFrame(frameNumber: 1))
        await host.requestRecovery(MirageRecoveryRequest(scope: .fullStream(11), cause: .manual))
        await host.stop()

        let hostSnapshot = await host.snapshot()
        #expect(hostSnapshot.started)
        #expect(hostSnapshot.submittedFrames == [1])
        #expect(hostSnapshot.recoveryCauses == [.manual])
        #expect(hostSnapshot.stopped)

        let graph = FakeEncodeGraph(unit: unit)
        let batch = try await graph.encode(FakeEncodeWork(streamID: 11))
        #expect(batch.units == [unit])

        let client = FakeClientMediaPipeline()
        await client.updateTopology(topology)
        await client.processPacket(FakeMediaPacket(streamID: 11, topologyID: topologyID, mediaUnitID: .primary, frameNumber: 1))
        await client.requestRecovery(MirageRecoveryScope(streamID: 11, topologyID: topologyID, mediaUnitID: .primary))
        await client.stop()

        let clientSnapshot = await client.snapshot()
        #expect(clientSnapshot.topologyIDs == [topologyID])
        #expect(clientSnapshot.packetFrameNumbers == [1])
        #expect(clientSnapshot.recoveryScopes.count == 1)
        #expect(clientSnapshot.stopped)

        let compositor = FakeRenderCompositor()
        await compositor.update(
            FakeDecodedMediaUnit(
                streamID: 11,
                topologyID: topologyID,
                mediaUnitID: .primary,
                unitFrameNumber: 1,
                presentationTime: MiragePresentationTime(seconds: 0.5)
            )
        )
        #expect(await compositor.render(at: MiragePresentationDeadline(seconds: 0.25)) == nil)
        #expect(await compositor.render(at: MiragePresentationDeadline(seconds: 0.75)) == "frame-1")
    }
}

private struct FakeCapturedFrame: Sendable {
    let frameNumber: UInt32
}

private struct FakeEncodeWork: Sendable {
    let streamID: StreamID
}

private struct FakeMediaPacket: MirageMediaPacket {
    let streamID: StreamID
    let topologyID: MirageMediaTopologyID?
    let mediaUnitID: MirageMediaUnitID?
    let frameNumber: UInt32
}

private struct FakeDecodedMediaUnit: MirageDecodedMediaUnit {
    let streamID: StreamID
    let topologyID: MirageMediaTopologyID
    let mediaUnitID: MirageMediaUnitID
    let unitFrameNumber: UInt32
    let presentationTime: MiragePresentationTime
}

private struct FakeHostSnapshot: Sendable {
    let started: Bool
    let submittedFrames: [UInt32]
    let recoveryCauses: [MirageRecoveryCause]
    let stopped: Bool
}

private actor FakeHostMediaPipeline: MirageHostMediaPipeline {
    private var isStarted = false
    private var submittedFrames: [UInt32] = []
    private var recoveryCauses: [MirageRecoveryCause] = []
    private var isStopped = false

    func start() async throws {
        isStarted = true
    }

    func submit(_ frame: FakeCapturedFrame) async {
        submittedFrames.append(frame.frameNumber)
    }

    func requestRecovery(_ request: MirageRecoveryRequest) async {
        recoveryCauses.append(request.cause)
    }

    func stop() async {
        isStopped = true
    }

    func snapshot() -> FakeHostSnapshot {
        FakeHostSnapshot(
            started: isStarted,
            submittedFrames: submittedFrames,
            recoveryCauses: recoveryCauses,
            stopped: isStopped
        )
    }
}

private actor FakeEncodeGraph: MirageEncodeGraph {
    private let unit: MirageEncodedMediaUnit

    init(unit: MirageEncodedMediaUnit) {
        self.unit = unit
    }

    func encode(_ work: FakeEncodeWork) async throws -> MirageEncodedMediaBatch {
        MirageEncodedMediaBatch(streamID: work.streamID, topologyID: unit.topologyID, units: [unit])
    }
}

private struct FakeClientSnapshot: Sendable {
    let topologyIDs: [MirageMediaTopologyID]
    let packetFrameNumbers: [UInt32]
    let recoveryScopes: [MirageRecoveryScope]
    let stopped: Bool
}

private actor FakeClientMediaPipeline: MirageClientMediaPipeline {
    private var topologyIDs: [MirageMediaTopologyID] = []
    private var packetFrameNumbers: [UInt32] = []
    private var recoveryScopes: [MirageRecoveryScope] = []
    private var isStopped = false

    func processPacket(_ packet: FakeMediaPacket) async {
        packetFrameNumbers.append(packet.frameNumber)
    }

    func updateTopology(_ topology: MirageMediaTopology) async {
        topologyIDs.append(topology.id)
    }

    func requestRecovery(_ scope: MirageRecoveryScope) async {
        recoveryScopes.append(scope)
    }

    func stop() async {
        isStopped = true
    }

    func snapshot() -> FakeClientSnapshot {
        FakeClientSnapshot(
            topologyIDs: topologyIDs,
            packetFrameNumbers: packetFrameNumbers,
            recoveryScopes: recoveryScopes,
            stopped: isStopped
        )
    }
}

private actor FakeRenderCompositor: MirageRenderCompositor {
    private var latestUnit: FakeDecodedMediaUnit?

    func update(_ unit: FakeDecodedMediaUnit) async {
        latestUnit = unit
    }

    func render(at deadline: MiragePresentationDeadline) async -> String? {
        guard let latestUnit,
              deadline.rawValue >= latestUnit.presentationTime.rawValue else {
            return nil
        }
        return "frame-\(latestUnit.unitFrameNumber)"
    }
}
