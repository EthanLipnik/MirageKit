//
//  AppAtlasRuntimeQualityHostTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 6/4/26.
//

#if os(macOS)
@testable import MirageKitHost
import CoreGraphics
import Foundation
import MirageConnectivity
import MirageKit
import Testing
import MirageCore
import MirageMedia
import MirageWire

@Suite("App Atlas Runtime Quality Host")
struct AppAtlasRuntimeQualityHostTests {
    @MainActor
    @Test("Logical app encoder settings update atlas media context")
    func logicalAppEncoderSettingsUpdateAtlasMediaContext() async throws {
        let pair = try await makeLoopbackControlPair()
        try await pair.startAuthenticatedSessions()
        let harness = try await Self.makeHostHarness(pair: pair)

        let host = harness.host
        let logicalStreamID: StreamID = 10
        let mediaStreamID: StreamID = 90
        let context = await Self.makeRunningContext(streamID: mediaStreamID, windowID: 100)
        host.streamsByID[mediaStreamID] = context
        await Self.registerAppAtlasSession(
            host: host,
            client: harness.clientContext.client,
            logicalStreamID: logicalStreamID,
            mediaStreamID: mediaStreamID
        )

        await host.handleStreamEncoderSettingsChange(
            MirageWire.StreamEncoderSettingsChangeMessage(
                streamID: logicalStreamID,
                bitrate: 24_000_000,
                bitrateAdaptationCeiling: 40_000_000,
                targetFrameRate: 30
            ),
            from: harness.clientContext
        )

        #expect(await context.encoderSettings.bitrate == 24_000_000)
        #expect(await context.bitrateAdaptationCeiling == 40_000_000)
        #expect(await context.streamStartSnapshot.targetFrameRate == 30)

        await harness.stop()
    }

    @MainActor
    @Test("App-atlas media stream ignores encoder settings scale")
    func appAtlasMediaStreamIgnoresEncoderSettingsScale() async throws {
        let pair = try await makeLoopbackControlPair()
        try await pair.startAuthenticatedSessions()
        let harness = try await Self.makeHostHarness(pair: pair)

        let host = harness.host
        let logicalStreamID: StreamID = 10
        let mediaStreamID: StreamID = 90
        let context = await Self.makeRunningContext(streamID: mediaStreamID, windowID: 100)
        host.streamsByID[mediaStreamID] = context
        host.appAtlasCoordinatorsByClientID[harness.clientContext.client.id] = Self.makeCoordinator(
            mediaStreamID: mediaStreamID,
            context: context
        )
        await Self.registerAppAtlasSession(
            host: host,
            client: harness.clientContext.client,
            logicalStreamID: logicalStreamID,
            mediaStreamID: mediaStreamID
        )

        await host.handleStreamEncoderSettingsChange(
            MirageWire.StreamEncoderSettingsChangeMessage(
                streamID: logicalStreamID,
                streamScale: 0.5
            ),
            from: harness.clientContext
        )

        #expect(abs((await context.streamScale) - 1.0) < 0.001)

        await harness.stop()
    }

    @MainActor
    @Test("App-atlas governance emits presentation policies without bitrate targets")
    func appAtlasGovernanceEmitsPresentationPoliciesWithoutBitrateTargets() async throws {
        let pair = try await makeLoopbackControlPair()
        try await pair.startAuthenticatedSessions()
        let harness = try await Self.makeHostHarness(pair: pair)

        do {
            let host = harness.host
            let bundleID = "com.example.Editor"
            let mediaStreamID: StreamID = 90
            await Self.startAppSession(host: host, client: harness.clientContext.client, bundleID: bundleID)
            _ = await host.appStreamManager.addWindowToSession(
                bundleIdentifier: bundleID,
                windowID: 100,
                streamID: 10,
                title: "Editor",
                width: 800,
                height: 600,
                isResizable: true,
                slotIndex: 0,
                mediaStreamID: mediaStreamID
            )
            _ = await host.appStreamManager.addWindowToSession(
                bundleIdentifier: bundleID,
                windowID: 101,
                streamID: 11,
                title: "Preview",
                width: 800,
                height: 600,
                isResizable: true,
                slotIndex: 1,
                mediaStreamID: mediaStreamID
            )

            await host.recomputeAppSessionBitrateBudget(bundleIdentifier: bundleID, reason: "test")

            let updateMessage = try await nextControlMessage(
                from: harness.clientControl,
                matching: { $0.type == .streamPolicyUpdate }
            )
            let update = try updateMessage.decode(MirageWire.StreamPolicyUpdateMessage.self)
            let appSession = try #require(await host.appStreamManager.session(bundleIdentifier: bundleID))

            #expect(update.policies.count == 2)
            #expect(update.policies.allSatisfy { $0.targetBitrateBps == nil })
            #expect(appSession.streamBitrateTargetsByStreamID.isEmpty)
        } catch {
            await harness.stop()
            throw error
        }

        await harness.stop()
    }

    @MainActor
    @Test("Dedicated app governance keeps per-stream bitrate targets")
    func dedicatedAppGovernanceKeepsPerStreamBitrateTargets() async throws {
        let pair = try await makeLoopbackControlPair()
        try await pair.startAuthenticatedSessions()
        let harness = try await Self.makeHostHarness(pair: pair)

        do {
            let host = harness.host
            let bundleID = "com.example.Editor"
            let firstStreamID: StreamID = 20
            let secondStreamID: StreamID = 21
            host.streamsByID[firstStreamID] = await Self.makeRunningContext(streamID: firstStreamID, windowID: 200)
            host.streamsByID[secondStreamID] = await Self.makeRunningContext(streamID: secondStreamID, windowID: 201)
            await Self.startAppSession(host: host, client: harness.clientContext.client, bundleID: bundleID)
            _ = await host.appStreamManager.addWindowToSession(
                bundleIdentifier: bundleID,
                windowID: 200,
                streamID: firstStreamID,
                title: "Editor",
                width: 800,
                height: 600,
                isResizable: true,
                slotIndex: 0,
                mediaStreamID: firstStreamID
            )
            _ = await host.appStreamManager.addWindowToSession(
                bundleIdentifier: bundleID,
                windowID: 201,
                streamID: secondStreamID,
                title: "Preview",
                width: 800,
                height: 600,
                isResizable: true,
                slotIndex: 1,
                mediaStreamID: secondStreamID
            )

            await host.recomputeAppSessionBitrateBudget(bundleIdentifier: bundleID, reason: "test")

            let updateMessage = try await nextControlMessage(
                from: harness.clientControl,
                matching: { $0.type == .streamPolicyUpdate }
            )
            let update = try updateMessage.decode(MirageWire.StreamPolicyUpdateMessage.self)
            let appSession = try #require(await host.appStreamManager.session(bundleIdentifier: bundleID))

            #expect(update.policies.count == 2)
            #expect(update.policies.allSatisfy { $0.targetBitrateBps != nil })
            #expect(appSession.streamBitrateTargetsByStreamID.keys.sorted() == [firstStreamID, secondStreamID])
        } catch {
            await harness.stop()
            throw error
        }

        await harness.stop()
    }

    private struct HostHarness {
        let host: MirageHostService
        let clientContext: ClientContext
        let clientControl: MirageControlChannel
        let serverControl: MirageControlChannel
        let pair: LoopbackControlPair

        @MainActor
        func stop() async {
            await clientControl.cancel()
            await serverControl.cancel()
            await pair.stop()
        }
    }

    @MainActor
    private static func makeHostHarness(pair: LoopbackControlPair) async throws -> HostHarness {
        let serverControlTask = Task {
            try await MirageControlChannel.accept(from: pair.server)
        }
        let clientControl = try await MirageControlChannel.open(on: pair.client)
        let serverControl = try await serverControlTask.value
        let host = MirageHostService(hostName: "Runtime Quality Host")
        let client = MirageConnectedClient(
            id: UUID(),
            name: "Test iPad",
            deviceType: .iPad,
            connectedAt: Date(),
            identityKeyID: "test-client-key"
        )
        let clientContext = ClientContext(
            sessionID: pair.server.id,
            client: client,
            controlChannel: serverControl,
            transferEngine: MirageTransferEngine(session: pair.server),
            pathSnapshot: nil
        )
        host.connectedClients = [client]
        host.clientsBySessionID[clientContext.sessionID] = clientContext
        host.clientsByID[client.id] = clientContext
        host.singleClientSessionID = clientContext.sessionID
        return HostHarness(
            host: host,
            clientContext: clientContext,
            clientControl: clientControl,
            serverControl: serverControl,
            pair: pair
        )
    }

    @MainActor
    private static func startAppSession(
        host: MirageHostService,
        client: MirageConnectedClient,
        bundleID: String
    ) async {
        _ = await host.appStreamManager.startAppSession(
            bundleIdentifier: bundleID,
            appName: "Editor",
            appPath: "/Applications/Editor.app",
            clientID: client.id,
            clientName: client.name,
            requestedDisplayResolution: CGSize(width: 800, height: 600),
            requestedClientScaleFactor: nil,
            maxVisibleSlots: 2,
            bitrateBudgetBps: 24_000_000
        )
        await host.appStreamManager.stopMonitoring()
        await host.appStreamManager.markSessionStreaming(bundleID)
    }

    @MainActor
    private static func registerAppAtlasSession(
        host: MirageHostService,
        client: MirageConnectedClient,
        logicalStreamID: StreamID,
        mediaStreamID: StreamID
    ) async {
        let bundleID = "com.example.Editor"
        let window = Self.window(id: 100, title: "Editor")
        await Self.startAppSession(host: host, client: client, bundleID: bundleID)
        _ = await host.appStreamManager.addWindowToSession(
            bundleIdentifier: bundleID,
            windowID: window.id,
            streamID: logicalStreamID,
            title: window.title,
            width: Int(window.frame.width),
            height: Int(window.frame.height),
            isResizable: true,
            slotIndex: 0,
            mediaStreamID: mediaStreamID
        )
        host.registerActiveStreamSession(
            MirageStreamSession(id: logicalStreamID, window: window, client: client)
        )
    }

    private static func makeRunningContext(streamID: StreamID, windowID: WindowID) async -> StreamContext {
        let context = StreamContext(
            streamID: streamID,
            windowID: windowID,
            encoderConfig: .highQuality,
            maxPacketSize: MirageWire.mirageDefaultMaxPacketSize
        )
        await context.configureRunningForAppAtlasRuntimeQualityHostTest()
        return context
    }

    private static func makeCoordinator(
        mediaStreamID: StreamID,
        context: StreamContext
    ) -> AppAtlasMediaCoordinator {
        AppAtlasMediaCoordinator(
            mediaStreamID: mediaStreamID,
            context: context,
            encoderConfig: .highQuality,
            latencyMode: .lowestLatency,
            hostBufferingPolicy: .freshestFrame,
            capturePressureProfile: .baseline,
            targetFrameRate: 60,
            sendPacketWithMetadata: { _, _, completion in completion(nil) },
            onSendError: { _ in },
            sendMediaUpdate: { _ in },
            publishOverlayRegions: { _, _ in }
        )
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

private extension StreamContext {
    func configureRunningForAppAtlasRuntimeQualityHostTest() {
        isRunning = true
    }
}
#endif
