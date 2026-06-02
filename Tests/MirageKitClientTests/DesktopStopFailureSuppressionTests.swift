//
//  DesktopStopFailureSuppressionTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/13/26.
//
//  Coverage for suppressing startup-failure delivery after an explicit local desktop stop.
//

@testable import MirageKit
@testable import MirageKitClient
import CoreGraphics
import Foundation
import Loom
import Testing

#if os(macOS)
@Suite("Desktop Stop Failure Suppression")
struct DesktopStopFailureSuppressionTests {
    @MainActor
    @Test("Explicit desktop stop suppresses terminal startup failure delivery")
    func explicitDesktopStopSuppressesTerminalStartupFailureDelivery() async {
        let service = MirageClientService(deviceName: "Test Device")
        let delegate = DelegateSpy()
        let streamID: StreamID = 55

        service.delegate = delegate
        service.desktopStreamID = streamID
        service.desktopSessionID = UUID()
        service.desktopStreamMode = .unified
        service.pendingLocalDesktopStopStreamID = streamID
        service.pendingLocalDesktopStopSessionID = service.desktopSessionID

        let failure = StreamController.TerminalStartupFailure(
            reason: .startupKeyframeTimeout,
            hardRecoveryAttempts: 1,
            waitReason: "startup-hard-recovery"
        )

        await service.handleTerminalStartupFailure(failure, for: streamID)

        #expect(delegate.errorCount == 0)
        #expect(service.desktopStreamID == nil)
        #expect(service.desktopSessionID == nil)
        #expect(service.desktopStreamMode == nil)
        #expect(service.pendingLocalDesktopStopStreamID == nil)
        #expect(service.pendingLocalDesktopStopSessionID == nil)
    }

    @MainActor
    @Test("AWDL desktop startup requires explicit scene-local geometry")
    func awdlDesktopStartupRequiresExplicitSceneLocalGeometry() throws {
        let service = MirageClientService(deviceName: "Test Device")
        service.handleControlPathUpdate(Self.manualSnapshot(kind: .awdl, mediaProfile: .awdlRadio))

        #expect(throws: MirageError.self) {
            try service.resolvedDesktopStartupBaseResolution(
                displayResolution: nil,
                useHostResolution: false
            )
        }

        let explicitResolution = try service.resolvedDesktopStartupBaseResolution(
            displayResolution: CGSize(width: 1366, height: 1024),
            useHostResolution: false
        )
        #expect(explicitResolution == CGSize(width: 1366, height: 1024))

        let hostResolutionFallback = try service.resolvedDesktopStartupBaseResolution(
            displayResolution: nil,
            useHostResolution: true
        )
        #expect(hostResolutionFallback.width > 0)
        #expect(hostResolutionFallback.height > 0)
    }

    @MainActor
    @Test("AWDL desktop restart disables low latency high resolution compression boost")
    func awdlDesktopRestartDisablesLowLatencyHighResolutionCompressionBoost() throws {
        let service = MirageClientService(deviceName: "Test Device")
        let previousContractID = try #require(UUID(uuidString: "ABCDEF01-2345-6789-ABCD-EF0123456789"))
        service.handleControlPathUpdate(Self.manualSnapshot(kind: .awdl, mediaProfile: .awdlRadio))

        var request = StartDesktopStreamMessage(
            startupRequestID: UUID(),
            scaleFactor: 2,
            displayWidth: 1376,
            displayHeight: 1032,
            targetFrameRate: 120,
            streamScale: 1,
            audioConfiguration: MirageAudioConfiguration(enabled: false),
            dataPort: nil,
            useHostResolution: false,
            mediaMaxPacketSize: 1180,
            desktopGeometryContractID: previousContractID,
            desktopGeometryDisplayPixelWidth: 2752,
            desktopGeometryDisplayPixelHeight: 2064,
            desktopGeometryEncodedPixelWidth: 2752,
            desktopGeometryEncodedPixelHeight: 2064,
            desktopGeometryRefreshTargetHz: 60
        )
        request.latencyMode = .lowestLatency
        request.hostBufferingPolicy = .freshestFrame
        request.lowLatencyHighResolutionCompressionBoost = true
        request.encoderMaxWidth = 2752
        request.encoderMaxHeight = 2064

        let rebuilt = try #require(service.rebuiltDesktopRestartRequest(from: request))

        #expect(rebuilt.latencyMode == .balanced)
        #expect(rebuilt.hostBufferingPolicy == .stability)
        #expect(rebuilt.lowLatencyHighResolutionCompressionBoost == false)
        #expect(rebuilt.desktopGeometryContractID == previousContractID)
        #expect(rebuilt.targetFrameRate == 60)
    }

    @MainActor
    @Test("Terminal startup desktop restart preserves request contract")
    func terminalStartupDesktopRestartPreservesRequestContract() async throws {
        let originalRequestID = try #require(UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"))
        let restartRequestID = try #require(UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"))
        var request = StartDesktopStreamMessage(
            startupRequestID: originalRequestID,
            scaleFactor: 2,
            displayWidth: 2732,
            displayHeight: 2048,
            targetFrameRate: 120,
            streamScale: 1,
            audioConfiguration: MirageAudioConfiguration(enabled: true),
            dataPort: 7341,
            useHostResolution: false,
            mediaMaxPacketSize: 1180
        )
        request.keyFrameInterval = 240
        request.captureQueueDepth = 8
        request.colorDepth = .ultra
        request.mode = .secondary
        request.cursorPresentation = .simulatedCursor
        request.enteredBitrate = 180_000_000
        request.bitrate = 170_000_000
        request.latencyMode = .lowestLatency
        request.allowRuntimeQualityAdjustment = true
        request.lowLatencyHighResolutionCompressionBoost = true
        request.disableResolutionCap = true
        request.bitrateAdaptationCeiling = 220_000_000
        request.encoderMaxWidth = 3840
        request.encoderMaxHeight = 2160
        request.upscalingMode = .spatial
        request.codec = .hevc

        let restarted = StartDesktopStreamMessage(copying: request, startupRequestID: restartRequestID)

        #expect(restarted.startupRequestID == restartRequestID)
        #expect(restarted.startupRequestID != request.startupRequestID)
        #expect(restarted.scaleFactor == request.scaleFactor)
        #expect(restarted.displayWidth == request.displayWidth)
        #expect(restarted.displayHeight == request.displayHeight)
        #expect(restarted.targetFrameRate == request.targetFrameRate)
        #expect(restarted.streamScale == request.streamScale)
        #expect(restarted.audioConfiguration == request.audioConfiguration)
        #expect(restarted.dataPort == request.dataPort)
        #expect(restarted.useHostResolution == request.useHostResolution)
        #expect(restarted.mediaMaxPacketSize == request.mediaMaxPacketSize)
        #expect(restarted.keyFrameInterval == request.keyFrameInterval)
        #expect(restarted.captureQueueDepth == request.captureQueueDepth)
        #expect(restarted.colorDepth == request.colorDepth)
        #expect(restarted.mode == request.mode)
        #expect(restarted.cursorPresentation == request.cursorPresentation)
        #expect(restarted.enteredBitrate == request.enteredBitrate)
        #expect(restarted.bitrate == request.bitrate)
        #expect(restarted.latencyMode == request.latencyMode)
        #expect(restarted.allowRuntimeQualityAdjustment == request.allowRuntimeQualityAdjustment)
        #expect(restarted.lowLatencyHighResolutionCompressionBoost == request.lowLatencyHighResolutionCompressionBoost)
        #expect(restarted.disableResolutionCap == request.disableResolutionCap)
        #expect(restarted.bitrateAdaptationCeiling == request.bitrateAdaptationCeiling)
        #expect(restarted.encoderMaxWidth == request.encoderMaxWidth)
        #expect(restarted.encoderMaxHeight == request.encoderMaxHeight)
        #expect(restarted.upscalingMode == request.upscalingMode)
        #expect(restarted.codec == request.codec)
    }

    @MainActor
    @Test("Terminal startup desktop restart rebuilds geometry contract")
    func terminalStartupDesktopRestartRebuildsGeometryContract() throws {
        let service = MirageClientService(deviceName: "Test Device")
        let staleContractID = try #require(UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC"))
        var request = StartDesktopStreamMessage(
            startupRequestID: UUID(),
            scaleFactor: 1,
            displayWidth: 1,
            displayHeight: 1,
            targetFrameRate: 120,
            streamScale: 1,
            audioConfiguration: MirageAudioConfiguration(enabled: false),
            dataPort: nil,
            useHostResolution: false,
            mediaMaxPacketSize: 1180,
            desktopGeometryContractID: staleContractID,
            desktopGeometryDisplayPixelWidth: 1,
            desktopGeometryDisplayPixelHeight: 1,
            desktopGeometryEncodedPixelWidth: 1,
            desktopGeometryEncodedPixelHeight: 1,
            desktopGeometryRefreshTargetHz: 120
        )
        request.encoderMaxWidth = 2752
        request.encoderMaxHeight = 2064

        let rebuilt = try #require(service.rebuiltDesktopRestartRequest(from: request))
        let currentResolution = MirageStreamGeometry.normalizedLogicalSize(service.mainDisplayResolution)

        #expect(rebuilt.startupRequestID != request.startupRequestID)
        #expect(rebuilt.desktopGeometryContractID != staleContractID)
        #expect(rebuilt.desktopGeometryContractID == service.desktopResizeCoordinator.lastSentTarget?.contractID)
        #expect(rebuilt.displayWidth == Int(currentResolution.width))
        #expect(rebuilt.displayHeight == Int(currentResolution.height))
        #expect(rebuilt.desktopGeometryDisplayPixelWidth != 1)
        #expect(rebuilt.desktopGeometryDisplayPixelHeight != 1)
        #expect(rebuilt.encoderMaxWidth == request.encoderMaxWidth)
        #expect(rebuilt.encoderMaxHeight == request.encoderMaxHeight)
    }

    @MainActor
    @Test("AWDL terminal startup restart uses pending scene-local geometry")
    func awdlTerminalStartupRestartUsesPendingSceneLocalGeometry() throws {
        let service = MirageClientService(deviceName: "Test Device")
        service.handleControlPathUpdate(Self.manualSnapshot(kind: .awdl, mediaProfile: .awdlRadio))
        let staleContractID = try #require(UUID(uuidString: "EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE"))
        let pendingContractID = try #require(UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF"))
        service.desktopResizeCoordinator.lastSentTarget = DesktopResizeCoordinator.RequestGeometry(
            contractID: staleContractID,
            logicalResolution: CGSize(width: 1, height: 1),
            displayScaleFactor: 1,
            requestedStreamScale: 1,
            encoderMaxWidth: 1,
            encoderMaxHeight: 1
        )
        let pendingTarget = DesktopResizeCoordinator.RequestGeometry(
            contractID: pendingContractID,
            logicalResolution: CGSize(width: 1600, height: 1200),
            displayScaleFactor: 1.72,
            requestedStreamScale: 1,
            encoderMaxWidth: 2752,
            encoderMaxHeight: 2064
        )
        service.desktopResizeCoordinator.queueLatestTarget(pendingTarget)

        var request = StartDesktopStreamMessage(
            startupRequestID: UUID(),
            scaleFactor: 2,
            displayWidth: 1512,
            displayHeight: 982,
            targetFrameRate: 60,
            streamScale: 1,
            audioConfiguration: MirageAudioConfiguration(enabled: false),
            dataPort: nil,
            useHostResolution: false,
            mediaMaxPacketSize: 1180,
            desktopGeometryContractID: staleContractID,
            desktopGeometryDisplayPixelWidth: 3024,
            desktopGeometryDisplayPixelHeight: 1964,
            desktopGeometryEncodedPixelWidth: 2752,
            desktopGeometryEncodedPixelHeight: 1964,
            desktopGeometryRefreshTargetHz: 60
        )
        request.encoderMaxWidth = 2752
        request.encoderMaxHeight = 2064

        let rebuilt = try #require(service.rebuiltDesktopRestartRequest(from: request))

        #expect(rebuilt.startupRequestID != request.startupRequestID)
        #expect(rebuilt.desktopGeometryContractID != staleContractID)
        #expect(rebuilt.desktopGeometryContractID == pendingContractID)
        #expect(rebuilt.desktopGeometryContractID == service.desktopResizeCoordinator.lastSentTarget?.contractID)
        #expect(rebuilt.displayWidth == 1600)
        #expect(rebuilt.displayHeight == 1200)
        #expect(rebuilt.desktopGeometryDisplayPixelWidth == 2752)
        #expect(rebuilt.desktopGeometryDisplayPixelHeight == 2064)
        #expect(rebuilt.encoderMaxWidth == request.encoderMaxWidth)
        #expect(rebuilt.encoderMaxHeight == request.encoderMaxHeight)
    }

    @MainActor
    @Test("AWDL terminal startup restart reuses previous geometry contract when no live target exists")
    func awdlTerminalStartupRestartReusesPreviousGeometryContractWhenNoLiveTargetExists() throws {
        let service = MirageClientService(deviceName: "Test Device")
        service.handleControlPathUpdate(Self.manualSnapshot(kind: .awdl, mediaProfile: .awdlRadio))
        let previousContractID = try #require(UUID(uuidString: "12345678-1234-1234-1234-123456789ABC"))
        service.desktopResizeCoordinator.lastSentTarget = nil

        var request = StartDesktopStreamMessage(
            startupRequestID: UUID(),
            scaleFactor: 2,
            displayWidth: 1376,
            displayHeight: 1032,
            targetFrameRate: 45,
            streamScale: 1,
            audioConfiguration: MirageAudioConfiguration(enabled: false),
            dataPort: nil,
            useHostResolution: false,
            mediaMaxPacketSize: 1180,
            desktopGeometryContractID: previousContractID,
            desktopGeometrySceneIdentity: "scene-a",
            desktopGeometryDisplayPixelWidth: 2752,
            desktopGeometryDisplayPixelHeight: 2064,
            desktopGeometryEncodedPixelWidth: 2752,
            desktopGeometryEncodedPixelHeight: 2064,
            desktopGeometryRefreshTargetHz: 45
        )
        request.encoderMaxWidth = 2752
        request.encoderMaxHeight = 2064

        let rebuilt = try #require(service.rebuiltDesktopRestartRequest(from: request))

        #expect(rebuilt.startupRequestID != request.startupRequestID)
        #expect(rebuilt.desktopGeometryContractID == previousContractID)
        #expect(rebuilt.desktopGeometrySceneIdentity == "scene-a")
        #expect(rebuilt.desktopGeometryRefreshTargetHz == 45)
        #expect(rebuilt.targetFrameRate == 45)
        #expect(rebuilt.displayWidth == request.displayWidth)
        #expect(rebuilt.displayHeight == request.displayHeight)
        #expect(rebuilt.desktopGeometryDisplayPixelWidth == 2752)
        #expect(rebuilt.desktopGeometryDisplayPixelHeight == 2064)
        #expect(service.desktopResizeCoordinator.lastSentTarget?.contractID == previousContractID)
        #expect(service.desktopResizeCoordinator.lastSentTarget?.sceneIdentity == "scene-a")
        #expect(service.desktopResizeCoordinator.lastSentTarget?.refreshTargetHz == 45)
    }

    @MainActor
    @Test("AWDL geometry rejection retry requires fresh scene-local geometry")
    func awdlGeometryRejectionRetryRequiresFreshSceneLocalGeometry() throws {
        let service = MirageClientService(deviceName: "Test Device")
        service.handleControlPathUpdate(Self.manualSnapshot(kind: .awdl, mediaProfile: .awdlRadio))
        let previousContractID = try #require(UUID(uuidString: "87654321-4321-4321-4321-CBA987654321"))
        let staleLastSentTarget = DesktopResizeCoordinator.RequestGeometry(
            contractID: previousContractID,
            sceneIdentity: "scene-a",
            refreshTargetHz: 45,
            logicalResolution: CGSize(width: 1376, height: 1032),
            displayScaleFactor: 2,
            requestedStreamScale: 1,
            encoderMaxWidth: 2752,
            encoderMaxHeight: 2064
        )
        service.desktopResizeCoordinator.lastSentTarget = staleLastSentTarget

        var request = StartDesktopStreamMessage(
            startupRequestID: UUID(),
            scaleFactor: 2,
            displayWidth: 1376,
            displayHeight: 1032,
            targetFrameRate: 45,
            streamScale: 1,
            audioConfiguration: MirageAudioConfiguration(enabled: false),
            dataPort: nil,
            useHostResolution: false,
            mediaMaxPacketSize: 1180,
            desktopGeometryContractID: previousContractID,
            desktopGeometrySceneIdentity: "scene-a",
            desktopGeometryDisplayPixelWidth: 2752,
            desktopGeometryDisplayPixelHeight: 2064,
            desktopGeometryEncodedPixelWidth: 2752,
            desktopGeometryEncodedPixelHeight: 2064,
            desktopGeometryRefreshTargetHz: 45
        )
        request.encoderMaxWidth = 2752
        request.encoderMaxHeight = 2064

        let rebuilt = service.rebuiltDesktopRestartRequest(
            from: request,
            requiresFreshAwdlGeometry: true
        )

        #expect(rebuilt == nil)
        #expect(service.desktopResizeCoordinator.lastSentTarget == staleLastSentTarget)
    }

    @MainActor
    @Test("Terminal startup host-resolution restart suppresses client geometry contract")
    func terminalStartupHostResolutionRestartSuppressesClientGeometryContract() throws {
        let service = MirageClientService(deviceName: "Test Device")
        let staleContractID = try #require(UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD"))
        service.desktopResizeCoordinator.lastSentTarget = DesktopResizeCoordinator.RequestGeometry(
            contractID: staleContractID,
            logicalResolution: CGSize(width: 2732, height: 2048),
            displayScaleFactor: 2,
            requestedStreamScale: 1,
            encoderMaxWidth: 2752,
            encoderMaxHeight: 2064
        )

        var request = StartDesktopStreamMessage(
            startupRequestID: UUID(),
            scaleFactor: 2,
            displayWidth: 2732,
            displayHeight: 2048,
            targetFrameRate: 60,
            streamScale: 1,
            audioConfiguration: MirageAudioConfiguration(enabled: false),
            dataPort: nil,
            useHostResolution: true,
            mediaMaxPacketSize: 1180,
            desktopGeometryContractID: staleContractID,
            desktopGeometryDisplayPixelWidth: 5464,
            desktopGeometryDisplayPixelHeight: 4096,
            desktopGeometryEncodedPixelWidth: 2752,
            desktopGeometryEncodedPixelHeight: 2064,
            desktopGeometryRefreshTargetHz: 60
        )
        request.encoderMaxWidth = 2752
        request.encoderMaxHeight = 2064

        let rebuilt = try #require(service.rebuiltDesktopRestartRequest(from: request))

        #expect(rebuilt.startupRequestID != request.startupRequestID)
        #expect(rebuilt.useHostResolution == true)
        #expect(rebuilt.displayWidth == request.displayWidth)
        #expect(rebuilt.displayHeight == request.displayHeight)
        #expect(rebuilt.desktopGeometryContractID == nil)
        #expect(rebuilt.desktopGeometrySceneIdentity == nil)
        #expect(rebuilt.desktopGeometryDisplayPixelWidth == nil)
        #expect(rebuilt.desktopGeometryDisplayPixelHeight == nil)
        #expect(rebuilt.desktopGeometryEncodedPixelWidth == nil)
        #expect(rebuilt.desktopGeometryEncodedPixelHeight == nil)
        #expect(rebuilt.desktopGeometryRefreshTargetHz == nil)
        #expect(service.desktopResizeCoordinator.lastSentTarget == nil)
    }

    @MainActor
    @Test("Terminal startup desktop restart is bounded to one attempt")
    func terminalStartupDesktopRestartIsBoundedToOneAttempt() async {
        let service = MirageClientService(deviceName: "Test Device")
        let streamID: StreamID = 56
        let request = StartDesktopStreamMessage(
            startupRequestID: UUID(),
            scaleFactor: 2,
            displayWidth: 2732,
            displayHeight: 2048,
            targetFrameRate: 120,
            streamScale: 1,
            audioConfiguration: MirageAudioConfiguration(enabled: false),
            dataPort: nil,
            useHostResolution: false,
            mediaMaxPacketSize: 1180
        )

        service.desktopStreamID = streamID
        service.lastDesktopStreamStartRequest = request
        service.desktopStreamRestartAttempts = 0

        #expect(service.hasDesktopStreamRestartBudget(streamID: streamID))
        service.desktopStreamRestartAttempts = service.desktopStreamRestartLimit
        #expect(!service.hasDesktopStreamRestartBudget(streamID: streamID))
        #expect(!service.hasDesktopStreamRestartBudget(streamID: streamID + 1))
    }

    @MainActor
    @Test("Non-desktop startup failure does not disconnect while desktop is starting")
    func nonDesktopStartupFailureDoesNotDisconnectWhileDesktopIsStarting() async {
        let service = MirageClientService(deviceName: "Test Device")
        let delegate = DelegateSpy()
        let failedStreamID: StreamID = 80
        let window = testWindow(bundleIdentifier: "com.example.Terminal")

        service.delegate = delegate
        service.activeStreams = [
            ClientStreamSession(
                id: failedStreamID,
                window: window,
                mediaStreamID: failedStreamID
            ),
        ]
        service.desktopStreamMode = .unified

        let failure = StreamController.TerminalStartupFailure(
            reason: .startupKeyframeTimeout,
            hardRecoveryAttempts: 1,
            waitReason: "startup-hard-recovery"
        )

        await service.handleTerminalStartupFailure(failure, for: failedStreamID)

        #expect(delegate.errorCount == 0)
        #expect(service.activeStreams.isEmpty)
        #expect(service.desktopStreamMode == .unified)
    }

    @MainActor
    @Test("App atlas startup failure reports app failure without delegate disconnect")
    func appAtlasStartupFailureReportsAppFailureWithoutDelegateDisconnect() async {
        let service = MirageClientService(deviceName: "Test Device")
        let delegate = DelegateSpy()
        let mediaStreamID: StreamID = 81
        let logicalStreamID: StreamID = 810
        let bundleIdentifier = "com.example.Terminal"
        let window = testWindow(bundleIdentifier: bundleIdentifier)
        var reportedFailure: MirageClientService.AppStreamStartupFailure?

        service.delegate = delegate
        service.onAppStreamStartupFailed = { failure in
            reportedFailure = failure
        }
        _ = service.sessionStore.createSession(
            streamID: logicalStreamID,
            mediaStreamID: mediaStreamID,
            window: window,
            hostName: "Host",
            minSize: nil
        )

        let failure = StreamController.TerminalStartupFailure(
            reason: .startupKeyframeTimeout,
            hardRecoveryAttempts: 1,
            waitReason: "startup-hard-recovery"
        )

        await service.handleTerminalStartupFailure(failure, for: mediaStreamID)

        #expect(delegate.errorCount == 0)
        #expect(reportedFailure?.bundleIdentifier == bundleIdentifier)
        #expect(service.sessionStore.activeSessions.isEmpty)
    }

    private static func manualSnapshot(
        kind: MirageNetworkPathKind,
        mediaProfile: MirageMediaPathProfile
    ) -> MirageNetworkPathSnapshot {
        MirageNetworkPathSnapshot(
            kind: kind,
            mediaProfile: mediaProfile,
            status: "satisfied",
            signature: "manual|\(kind.rawValue)|\(mediaProfile.rawValue)",
            interfaceNames: [],
            isExpensive: false,
            isConstrained: false,
            supportsIPv4: true,
            supportsIPv6: true,
            usesWiFi: false,
            usesWired: false,
            usesCellular: false,
            usesLoopback: false,
            usesOther: false,
            localEndpointDescription: nil,
            remoteEndpointDescription: nil
        )
    }
}

private final class DelegateSpy: MirageClientDelegate, @unchecked Sendable {
    private(set) var errorCount = 0

    @MainActor
    func didDisconnectFromHost(_: String) {}

    @MainActor
    func didEncounterError(_: Error) {
        errorCount += 1
    }

    @MainActor
    func hostSessionStateChanged(_: LoomSessionAvailability) {}
}

private func testWindow(bundleIdentifier: String) -> MirageWindow {
    MirageWindow(
        id: 1,
        title: "Terminal",
        application: MirageApplication(
            id: 1,
            bundleIdentifier: bundleIdentifier,
            name: "Terminal"
        ),
        frame: CGRect(x: 0, y: 0, width: 640, height: 480),
        isOnScreen: true,
        windowLayer: 0
    )
}
#endif
