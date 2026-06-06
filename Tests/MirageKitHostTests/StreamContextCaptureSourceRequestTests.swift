//
//  StreamContextCaptureSourceRequestTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 6/5/26.
//

#if os(macOS)
import CoreGraphics
import MirageKit
@testable import MirageKitHost
import Testing
import MirageMedia

@Suite("Stream Context Capture Source Requests")
struct StreamContextCaptureSourceRequestTests {
    @Test("Desktop display capture request preserves exclusions and best-resolution capture")
    func desktopDisplayCaptureRequestPreservesExclusionsAndBestResolution() async throws {
        let context = StreamContext(
            streamID: 88,
            windowID: 0,
            streamKind: .desktop,
            encoderConfig: MirageEncoderConfiguration.highQuality
                .withTargetFrameRate(72)
                .withOverrides(captureQueueDepth: 7),
            requestedAudioChannelCount: 6,
            captureShowsCursor: true
        )
        await context.setCapturedAudioHandler { _ in }

        let request = await context.desktopDisplayCaptureRequest(
            displayID: 42,
            outputSize: CGSize(width: 1920, height: 1080),
            captureResolution: nil,
            excludedWindowIDs: [100, 101]
        )

        guard case let .displayWindowSet(displayID, includedWindowIDs, excludedWindowIDs) = request.source else {
            Issue.record("Expected desktop capture with exclusions to use displayWindowSet")
            return
        }
        #expect(displayID == MirageHostDisplayID(42))
        #expect(includedWindowIDs.isEmpty)
        #expect(excludedWindowIDs == [100, 101])
        #expect(request.configuration.logicalSize == CGSize(width: 1920, height: 1080))
        #expect(request.configuration.captureResolution == nil)
        #expect(request.configuration.showsCursor)
        #expect(request.configuration.targetFrameRate == 72)
        #expect(request.configuration.queueDepth == 7)
        #expect(request.configuration.capturesAudio)
        #expect(request.configuration.audioConfiguration.enabled)
        #expect(request.configuration.audioChannelCount == 6)
    }

    @Test("Desktop display capture request preserves explicit resolution without exclusions")
    func desktopDisplayCaptureRequestPreservesExplicitResolutionWithoutExclusions() async throws {
        let context = StreamContext(
            streamID: 89,
            windowID: 0,
            streamKind: .desktop,
            encoderConfig: MirageEncoderConfiguration.highQuality.withTargetFrameRate(60)
        )
        let captureResolution = CGSize(width: 2560, height: 1440)

        let request = await context.desktopDisplayCaptureRequest(
            displayID: 77,
            outputSize: captureResolution,
            captureResolution: captureResolution,
            excludedWindowIDs: []
        )

        guard case let .display(displayID) = request.source else {
            Issue.record("Expected desktop capture without exclusions to use display")
            return
        }
        #expect(displayID == MirageHostDisplayID(77))
        #expect(request.configuration.logicalSize == captureResolution)
        #expect(request.configuration.captureResolution == captureResolution)
        #expect(!request.configuration.showsCursor)
        #expect(!request.configuration.capturesAudio)
        #expect(!request.configuration.audioConfiguration.enabled)
        #expect(request.configuration.audioChannelCount == MirageMedia.MirageAudioChannelLayout.stereo.channelCount)
    }

    @Test("App display capture request preserves destination rect and hides cursor")
    func appDisplayCaptureRequestPreservesDestinationRectAndHidesCursor() async throws {
        let context = StreamContext(
            streamID: 90,
            windowID: 0,
            streamKind: .appAtlas,
            encoderConfig: MirageEncoderConfiguration.highQuality,
            captureShowsCursor: true
        )
        let outputSize = CGSize(width: 1600, height: 900)
        let destinationRect = CGRect(x: 10, y: 20, width: 1500, height: 820)

        let request = await context.appStreamDisplayCaptureRequest(
            displayID: 55,
            outputSize: outputSize,
            destinationRect: destinationRect
        )

        guard case let .display(displayID) = request.source else {
            Issue.record("Expected app display capture to use display source")
            return
        }
        #expect(displayID == MirageHostDisplayID(55))
        #expect(request.configuration.logicalSize == outputSize)
        #expect(request.configuration.captureResolution == outputSize)
        #expect(request.configuration.sourceRect == nil)
        #expect(request.configuration.destinationRect == destinationRect)
        #expect(request.configuration.contentWindowID == nil)
        #expect(!request.configuration.showsCursor)
    }

    @Test("Shared display window capture request preserves source rect and content window")
    func sharedDisplayWindowCaptureRequestPreservesSourceRectAndContentWindow() async throws {
        let context = StreamContext(
            streamID: 91,
            windowID: 333,
            streamKind: .window,
            encoderConfig: MirageEncoderConfiguration.highQuality
                .withTargetFrameRate(90)
                .withOverrides(captureQueueDepth: 5),
            requestedAudioChannelCount: 1,
            captureShowsCursor: true
        )
        await context.setCapturedAudioHandler { _ in }
        let outputSize = CGSize(width: 1440, height: 900)
        let sourceRect = CGRect(x: 30, y: 40, width: 1000, height: 700)
        let destinationRect = CGRect(x: 0, y: 20, width: 1440, height: 860)

        let request = await context.sharedDisplayWindowCaptureRequest(
            displayID: 66,
            outputSize: outputSize,
            sourceRect: sourceRect,
            destinationRect: destinationRect,
            contentWindowID: 333,
            includedWindowIDs: [333, 444]
        )

        guard case let .displayWindowSet(displayID, includedWindowIDs, excludedWindowIDs) = request.source else {
            Issue.record("Expected shared display window capture to use displayWindowSet")
            return
        }
        #expect(displayID == MirageHostDisplayID(66))
        #expect(includedWindowIDs == [333, 444])
        #expect(excludedWindowIDs.isEmpty)
        #expect(request.configuration.logicalSize == outputSize)
        #expect(request.configuration.captureResolution == outputSize)
        #expect(request.configuration.sourceRect == sourceRect)
        #expect(request.configuration.destinationRect == destinationRect)
        #expect(request.configuration.contentWindowID == 333)
        #expect(!request.configuration.showsCursor)
        #expect(request.configuration.targetFrameRate == 90)
        #expect(request.configuration.queueDepth == 5)
        #expect(request.configuration.capturesAudio)
        #expect(request.configuration.audioChannelCount == 1)
    }

    @Test("App Atlas window capture request preserves window source and disables audio")
    func appAtlasWindowCaptureRequestPreservesWindowSourceAndDisablesAudio() {
        let request = AppAtlasWindowCaptureContext.captureRequest(
            windowID: 515,
            windowSize: CGSize(width: 640, height: 480),
            encoderConfig: MirageEncoderConfiguration.highQuality.withOverrides(captureQueueDepth: 4),
            targetFrameRate: 120
        )

        guard case let .window(windowID) = request.source else {
            Issue.record("Expected App Atlas capture to use window source")
            return
        }
        #expect(windowID == 515)
        #expect(request.configuration.logicalSize == CGSize(width: 640, height: 480))
        #expect(request.configuration.captureResolution == nil)
        #expect(request.configuration.sourceRect == nil)
        #expect(request.configuration.destinationRect == nil)
        #expect(request.configuration.contentWindowID == nil)
        #expect(!request.configuration.showsCursor)
        #expect(request.configuration.targetFrameRate == 120)
        #expect(request.configuration.queueDepth == 4)
        #expect(!request.configuration.capturesAudio)
        #expect(!request.configuration.audioConfiguration.enabled)
        #expect(request.configuration.audioChannelCount == nil)
    }
}
#endif
