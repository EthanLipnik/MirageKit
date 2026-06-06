//
//  AppAtlasRuntimeQualityTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 6/4/26.
//

@testable import MirageKit
@testable import MirageKitClient
import CoreGraphics
import Foundation
import Testing
import MirageConnectivity
import MirageCore
import MirageMedia
import MirageWire

#if os(macOS)
@Suite("App Atlas Runtime Quality")
struct AppAtlasRuntimeQualityTests {
    @MainActor
    @Test("Runtime quality media streams dedupe shared app-atlas sessions")
    func runtimeQualityMediaStreamsDedupeSharedAppAtlasSessions() {
        let service = MirageClientService(deviceName: "Runtime Quality Test")
        let desktopStreamID: StreamID = 1
        let dedicatedStreamID: StreamID = 2
        let atlasMediaStreamID: StreamID = 90
        let firstLogicalStreamID: StreamID = 10
        let secondLogicalStreamID: StreamID = 11

        service.desktopStreamID = desktopStreamID
        service.activeStreams = [
            ClientStreamSession(
                id: dedicatedStreamID,
                window: Self.window(id: 2, title: "Dedicated"),
                mediaStreamID: dedicatedStreamID
            ),
        ]
        service.sessionStore.registerSession(
            streamID: firstLogicalStreamID,
            mediaStreamID: atlasMediaStreamID,
            window: Self.window(id: 10, title: "Editor"),
            hostName: "Host",
            minSize: nil
        )
        service.sessionStore.registerSession(
            streamID: secondLogicalStreamID,
            mediaStreamID: atlasMediaStreamID,
            window: Self.window(id: 11, title: "Preview"),
            hostName: "Host",
            minSize: nil
        )

        #expect(service.activeRuntimeQualityMediaStreamIDs == [
            desktopStreamID,
            dedicatedStreamID,
            atlasMediaStreamID,
        ])
        #expect(service.activeRuntimeScalableStreamIDs == [
            desktopStreamID,
            dedicatedStreamID,
        ])
        #expect(service.activePresentationStreamIDs == [
            desktopStreamID,
            dedicatedStreamID,
            firstLogicalStreamID,
            secondLogicalStreamID,
        ])
        #expect(service.runtimeQualityMediaStreamID(for: firstLogicalStreamID) == atlasMediaStreamID)
        #expect(service.runtimeQualityMediaStreamID(for: atlasMediaStreamID) == atlasMediaStreamID)
    }

    @MainActor
    @Test("Runtime FPS cap targets app-atlas media stream")
    func runtimeFPSCapTargetsAppAtlasMediaStream() async throws {
        let pair = try await makeLoopbackControlPair()
        try await pair.startAuthenticatedSessions()

        let serverControlTask = Task {
            try await MirageControlChannel.accept(from: pair.server)
        }
        let clientControl = try await MirageControlChannel.open(on: pair.client)
        let serverControl = try await serverControlTask.value
        let serverReceiver = ControlMessageReceiver(channel: serverControl)

        do {
            let service = MirageClientService(deviceName: "Runtime Quality Test")
            let logicalStreamID: StreamID = 10
            let mediaStreamID: StreamID = 90
            service.loomSession = pair.client
            service.controlChannel = clientControl
            service.connectionState = .connected(host: "Host")
            service.sessionStore.registerSession(
                streamID: logicalStreamID,
                mediaStreamID: mediaStreamID,
                window: Self.window(id: 10, title: "Editor"),
                hostName: "Host",
                minSize: nil
            )
            service.refreshRateOverridesByStream[mediaStreamID] = 60

            await service.applyRuntimeWorkloadSafetyCap(
                targetFrameRate: 30,
                reason: .memoryPressure,
                triggerStreamID: logicalStreamID
            )

            let requestEnvelope = try await serverReceiver.next()
            #expect(requestEnvelope.type == .streamEncoderSettingsChange)
            let request = try requestEnvelope.decode(MirageWire.StreamEncoderSettingsChangeMessage.self)
            #expect(request.streamID == mediaStreamID)
            #expect(request.targetFrameRate == 30)
        } catch {
            await clientControl.cancel()
            await serverControl.cancel()
            await pair.stop()
            throw error
        }

        await clientControl.cancel()
        await serverControl.cancel()
        await pair.stop()
    }

    @MainActor
    @Test("Runtime scale downshift excludes shared app-atlas media")
    func runtimeScaleDownshiftExcludesSharedAppAtlasMedia() async throws {
        let pair = try await makeLoopbackControlPair()
        try await pair.startAuthenticatedSessions()

        let serverControlTask = Task {
            try await MirageControlChannel.accept(from: pair.server)
        }
        let clientControl = try await MirageControlChannel.open(on: pair.client)
        let serverControl = try await serverControlTask.value
        let serverReceiver = ControlMessageReceiver(channel: serverControl)

        do {
            let service = MirageClientService(deviceName: "Runtime Quality Test")
            let dedicatedStreamID: StreamID = 2
            let logicalStreamID: StreamID = 10
            let mediaStreamID: StreamID = 90
            service.loomSession = pair.client
            service.controlChannel = clientControl
            service.connectionState = .connected(host: "Host")
            service.activeStreams = [
                ClientStreamSession(
                    id: dedicatedStreamID,
                    window: Self.window(id: 2, title: "Dedicated"),
                    mediaStreamID: dedicatedStreamID
                ),
            ]
            service.sessionStore.registerSession(
                streamID: logicalStreamID,
                mediaStreamID: mediaStreamID,
                window: Self.window(id: 10, title: "Editor"),
                hostName: "Host",
                minSize: nil
            )

            let skippedCount = await service.applyRuntimeWorkloadSafetyScaleDownshift(
                streamIDs: [mediaStreamID],
                targetFrameRate: 30
            )
            #expect(skippedCount == 0)
            #expect(service.runtimeWorkloadSafetyScaleByStream[mediaStreamID] == nil)

            let downshiftedCount = await service.applyRuntimeWorkloadSafetyScaleDownshift(
                streamIDs: [dedicatedStreamID],
                targetFrameRate: 30
            )

            let requestEnvelope = try await serverReceiver.next()
            #expect(downshiftedCount == 1)
            #expect(requestEnvelope.type == .streamEncoderSettingsChange)
            let request = try requestEnvelope.decode(MirageWire.StreamEncoderSettingsChangeMessage.self)
            #expect(request.streamID == dedicatedStreamID)
            #expect(request.streamScale == 0.75)
            #expect(request.targetFrameRate == 30)
        } catch {
            await clientControl.cancel()
            await serverControl.cancel()
            await pair.stop()
            throw error
        }

        await clientControl.cancel()
        await serverControl.cancel()
        await pair.stop()
    }

    private static func window(id: WindowID, title: String) -> MirageMedia.MirageWindow {
        MirageMedia.MirageWindow(
            id: id,
            title: title,
            application: MirageMedia.MirageApplication(
                id: 1,
                bundleIdentifier: "com.example.Editor",
                name: "Editor"
            ),
            frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            isOnScreen: true,
            windowLayer: 0
        )
    }
}
#endif
