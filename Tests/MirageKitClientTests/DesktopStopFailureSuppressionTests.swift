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
    @Test("Terminal startup desktop restart preserves request contract")
    func terminalStartupDesktopRestartPreservesRequestContract() throws {
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
    @Test("Remote startup recovery restart preserves desktop tier")
    func remoteStartupRecoveryRestartPreservesDesktopTier() {
        let service = MirageClientService(deviceName: "Test Device")
        var request = StartDesktopStreamMessage(
            startupRequestID: UUID(),
            scaleFactor: 2,
            displayWidth: 2752,
            displayHeight: 2064,
            targetFrameRate: 120,
            streamScale: 1,
            audioConfiguration: MirageAudioConfiguration(enabled: true),
            dataPort: 7341,
            useHostResolution: false,
            mediaMaxPacketSize: 1180
        )
        request.enteredBitrate = 120_000_000
        request.bitrate = 120_000_000
        request.disableResolutionCap = true
        request.bitrateAdaptationCeiling = 220_000_000
        request.encoderMaxWidth = 4096
        request.encoderMaxHeight = 2304

        let preserved = service.remoteStartupRecoveryRestartRequest(from: request)

        #expect(preserved.targetFrameRate == request.targetFrameRate)
        #expect(preserved.enteredBitrate == request.enteredBitrate)
        #expect(preserved.bitrate == request.bitrate)
        #expect(preserved.disableResolutionCap == request.disableResolutionCap)
        #expect(preserved.bitrateAdaptationCeiling == request.bitrateAdaptationCeiling)
        #expect(preserved.encoderMaxWidth == request.encoderMaxWidth)
        #expect(preserved.encoderMaxHeight == request.encoderMaxHeight)
        #expect(preserved.startupRequestID == request.startupRequestID)
    }

    @MainActor
    @Test("Terminal startup desktop restart is bounded to one attempt")
    func terminalStartupDesktopRestartIsBoundedToOneAttempt() {
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
#endif
