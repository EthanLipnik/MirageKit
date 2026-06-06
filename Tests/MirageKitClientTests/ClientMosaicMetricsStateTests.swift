//
//  ClientMosaicMetricsStateTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 6/6/26.
//

@testable import MirageKitClient
import Foundation
import MirageMedia
import MirageWire
import Testing

@Suite("Client Mosaic Metrics State")
struct ClientMosaicMetricsStateTests {
    @MainActor
    @Test("Stream metrics update stores Mosaic tile plan and epoch summary")
    func streamMetricsUpdateStoresMosaicTilePlanAndEpochSummary() throws {
        let service = MirageClientService(deviceName: "Mosaic Metrics Test")
        let tilePlanID = MirageMediaTopologyID(
            rawValue: try #require(UUID(uuidString: "00000000-0000-0000-0000-00000000F1E1"))
        )
        let tilePlan = MirageMosaicTilePlan.fixedGrid(
            id: tilePlanID,
            epoch: 4,
            logicalSize: MiragePixelSize(width: 1280, height: 720),
            columns: 2,
            rows: 1,
            codec: .hevc
        )
        let dirtyTileID = MirageMosaicTileID(rawValue: "grid-1")
        let epochSummary = MirageMosaicEpochSummary(
            tilePlanID: tilePlanID,
            tilePlanEpoch: 4,
            frameNumber: 30,
            dirtyTileIDs: [dirtyTileID],
            reusedTileVersions: [MirageMosaicTileID(rawValue: "grid-0"): 2],
            updatedTileVersions: [dirtyTileID: 3]
        )
        let metrics = MirageWire.StreamMetricsMessage(
            streamID: 81,
            encodedFPS: 60,
            idleEncodedFPS: 0,
            droppedFrames: 0,
            activeQuality: 1,
            targetFrameRate: 60,
            mosaicTilePlan: tilePlan,
            mosaicEpochSummary: epochSummary
        )
        let message = try MirageWire.ControlMessage(type: .streamMetricsUpdate, content: metrics)

        service.handleStreamMetricsUpdate(message)

        #expect(service.mosaicTilePlansByStreamID[81] == tilePlan)
        #expect(service.mosaicEpochSummariesByStreamID[81] == epochSummary)
    }
}
