//
//  StreamContextMosaicCodecUnitEncoderPoolTests.swift
//  MirageKitHost
//
//  Created by Ethan Lipnik on 6/6/26.
//

#if os(macOS)
@testable import MirageKit
@testable import MirageKitHost
import Foundation
import MirageMedia
import Testing

@Suite("StreamContext Mosaic Codec Unit Encoder Pool")
struct StreamContextMosaicCodecUnitEncoderPoolTests {
    @Test("Pool creates and reuses codec-unit encoders for stable plan epoch")
    func poolCreatesAndReusesCodecUnitEncodersForStablePlanEpoch() async throws {
        let plan = MirageMosaicTilePlan.fixedGrid(
            epoch: 2,
            logicalSize: MiragePixelSize(width: 900, height: 300),
            columns: 3,
            rows: 1,
            codec: .hevc
        )
        let summary = MirageMosaicEpochSummary(
            tilePlanID: plan.id,
            tilePlanEpoch: plan.epoch,
            frameNumber: 8,
            dirtyTileIDs: [
                MirageMosaicTileID(rawValue: "grid-0"),
                MirageMosaicTileID(rawValue: "grid-2"),
            ],
            reusedTileVersions: [MirageMosaicTileID(rawValue: "grid-1"): 1],
            updatedTileVersions: [
                MirageMosaicTileID(rawValue: "grid-0"): 2,
                MirageMosaicTileID(rawValue: "grid-2"): 3,
            ]
        )
        let units = StreamContextMosaicMediaUnitPlanner().plannedUnits(
            plan: plan,
            summary: summary
        )
        let factory = RecordingVideoEncoderFactory()
        let pool = StreamContextMosaicCodecUnitEncoderPool()

        let prepared = try await pool.synchronize(
            units: units,
            configuration: MirageEncoderConfiguration(targetFrameRate: 60, bitrate: 10_000_000),
            latencyMode: .lowestLatency,
            mediaPathProfile: .unknown,
            inFlightLimit: 1,
            maximizePowerEfficiencyEnabled: false,
            factory: factory,
            createSessions: false
        )

        #expect(prepared.count == 2)
        #expect(factory.requests.count == 2)
        #expect(await pool.snapshot.keys.count == 2)

        _ = try await pool.synchronize(
            units: units,
            configuration: MirageEncoderConfiguration(targetFrameRate: 60, bitrate: 10_000_000),
            latencyMode: .lowestLatency,
            mediaPathProfile: .unknown,
            inFlightLimit: 1,
            maximizePowerEfficiencyEnabled: false,
            factory: factory,
            createSessions: false
        )

        #expect(factory.requests.count == 2)
        #expect(await pool.snapshot.keys.count == 2)
    }

    @Test("Pool replaces encoders when tile plan epoch changes")
    func poolReplacesEncodersWhenTilePlanEpochChanges() async throws {
        let firstPlan = MirageMosaicTilePlan.fixedGrid(
            epoch: 1,
            logicalSize: MiragePixelSize(width: 900, height: 300),
            columns: 3,
            rows: 1,
            codec: .hevc
        )
        let secondPlan = MirageMosaicTilePlan(
            id: firstPlan.id,
            epoch: 2,
            kind: firstPlan.kind,
            logicalSize: firstPlan.logicalSize,
            tiles: firstPlan.tiles,
            codecUnits: firstPlan.codecUnits
        )
        let tileID = MirageMosaicTileID(rawValue: "grid-1")
        let firstUnits = StreamContextMosaicMediaUnitPlanner().plannedUnits(
            plan: firstPlan,
            summary: summary(plan: firstPlan, tileID: tileID, version: 1)
        )
        let secondUnits = StreamContextMosaicMediaUnitPlanner().plannedUnits(
            plan: secondPlan,
            summary: summary(plan: secondPlan, tileID: tileID, version: 2)
        )
        let factory = RecordingVideoEncoderFactory()
        let pool = StreamContextMosaicCodecUnitEncoderPool()

        _ = try await pool.synchronize(
            units: firstUnits,
            configuration: MirageEncoderConfiguration(targetFrameRate: 60),
            latencyMode: .lowestLatency,
            mediaPathProfile: .unknown,
            inFlightLimit: 1,
            maximizePowerEfficiencyEnabled: false,
            factory: factory,
            createSessions: false
        )
        let firstSnapshot = await pool.snapshot

        _ = try await pool.synchronize(
            units: secondUnits,
            configuration: MirageEncoderConfiguration(targetFrameRate: 60),
            latencyMode: .lowestLatency,
            mediaPathProfile: .unknown,
            inFlightLimit: 1,
            maximizePowerEfficiencyEnabled: false,
            factory: factory,
            createSessions: false
        )
        let secondSnapshot = await pool.snapshot

        #expect(factory.requests.count == 2)
        #expect(firstSnapshot.keys.count == 1)
        #expect(secondSnapshot.keys.count == 1)
        #expect(firstSnapshot.keys.first?.planEpoch == 1)
        #expect(secondSnapshot.keys.first?.planEpoch == 2)
    }

    private func summary(
        plan: MirageMosaicTilePlan,
        tileID: MirageMosaicTileID,
        version: UInt32
    ) -> MirageMosaicEpochSummary {
        MirageMosaicEpochSummary(
            tilePlanID: plan.id,
            tilePlanEpoch: plan.epoch,
            frameNumber: version,
            dirtyTileIDs: [tileID],
            reusedTileVersions: [:],
            updatedTileVersions: [tileID: version]
        )
    }
}

private final class RecordingVideoEncoderFactory: @unchecked Sendable, MirageHostVideoEncoderFactoryBackend {
    struct Request {
        let codec: MirageVideoCodec
        let targetFrameRate: Int
        let latencyMode: MirageStreamLatencyMode
        let streamKind: VideoEncoder.StreamKind
        let mediaPathProfile: MirageMediaPathProfile
        let inFlightLimit: Int?
        let maximizePowerEfficiencyEnabled: Bool
    }

    private let lock = NSLock()
    private var recordedRequests: [Request] = []

    var requests: [Request] {
        lock.withLock { recordedRequests }
    }

    func makeVideoEncoder(
        configuration: MirageEncoderConfiguration,
        latencyMode: MirageStreamLatencyMode,
        streamKind: VideoEncoder.StreamKind,
        mediaPathProfile: MirageMediaPathProfile,
        inFlightLimit: Int?,
        maximizePowerEfficiencyEnabled: Bool
    ) -> VideoEncoder {
        record(Request(
            codec: configuration.codec,
            targetFrameRate: configuration.targetFrameRate,
            latencyMode: latencyMode,
            streamKind: streamKind,
            mediaPathProfile: mediaPathProfile,
            inFlightLimit: inFlightLimit,
            maximizePowerEfficiencyEnabled: maximizePowerEfficiencyEnabled
        ))
        return VideoEncoder(
            configuration: configuration,
            latencyMode: latencyMode,
            streamKind: streamKind,
            mediaPathProfile: mediaPathProfile,
            inFlightLimit: inFlightLimit,
            maximizePowerEfficiencyEnabled: maximizePowerEfficiencyEnabled
        )
    }

    private func record(_ request: Request) {
        lock.withLock {
            recordedRequests.append(request)
        }
    }
}
#endif
