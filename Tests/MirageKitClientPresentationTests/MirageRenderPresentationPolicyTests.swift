//
//  MirageRenderPresentationPolicyTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 6/5/26.
//

import CoreMedia
import CoreGraphics
import CoreVideo
import MirageDiagnostics
import MirageKit
@testable import MirageKitClientPresentation
import Testing
import MirageMedia

@Suite("Mirage Client Presentation Policy")
struct MirageRenderPresentationPolicyTests {
    @Test("Render mode policy clamps target frame rates")
    func renderModePolicyClampsTargetFrameRates() {
        #expect(MirageRenderModePolicy.normalizedTargetFPS(0) == 1)
        #expect(MirageRenderModePolicy.normalizedTargetFPS(60) == 60)
        #expect(MirageRenderModePolicy.normalizedTargetFPS(240) == 120)
    }

    @Test("Presentation timing clamps queue depth and immediate display behavior")
    func presentationTimingClampsQueueDepthAndImmediateDisplayBehavior() {
        let lowestLatencyTiming = MirageRenderPresentationTiming(
            targetFPS: 240,
            playoutDelayFrames: -2,
            latencyMode: .lowestLatency
        )
        let smoothestTiming = MirageRenderPresentationTiming(
            targetFPS: 60,
            playoutDelayFrames: 99,
            latencyMode: .smoothest
        )
        let realtimeTiming = MirageRenderPresentationTiming(
            targetFPS: 60,
            playoutDelayFrames: 2,
            latencyMode: .balanced,
            usesFixedRealtimeDisplayPolicy: true
        )

        #expect(lowestLatencyTiming.targetFPS == 120)
        #expect(lowestLatencyTiming.playoutDelayFrames == 0)
        #expect(lowestLatencyTiming.displaysImmediately)
        #expect(smoothestTiming.playoutDelayFrames == MirageMedia.MirageStreamCadenceTarget.maximumPlayoutDelayFrames)
        #expect(!smoothestTiming.displaysImmediately)
        #expect(!realtimeTiming.displaysImmediately)
    }

    @Test("Presentation timing schedules smoothest frames with bounded lead")
    func presentationTimingSchedulesSmoothestFramesWithBoundedLead() {
        let timing = MirageRenderPresentationTiming(
            targetFPS: 60,
            playoutDelayFrames: 4,
            latencyMode: .smoothest
        )

        let presentationTime = timing.presentationTime(
            referenceTime: 10,
            timescale: 600
        )

        #expect(timing.frameDuration == CMTime(value: 1, timescale: 60))
        #expect(presentationTime.seconds > 10)
        #expect(presentationTime.seconds <= 10.01)
    }

    @Test("Presentation latency policy keeps lowest-latency playout unbuffered")
    func presentationLatencyPolicyKeepsLowestLatencyPlayoutUnbuffered() {
        let policy = MiragePresentationLatencyPolicy(
            latencyMode: .lowestLatency,
            sourceFPS: 60,
            displayFPS: 240
        )

        #expect(policy.latencyMode == .lowestLatency)
        #expect(policy.sourceFPS == 60)
        #expect(policy.displayFPS == 120)
        #expect(policy.targetPlayoutDelayFrames == 0)
        #expect(policy.maximumQueueDepth == 1)
        #expect(policy.maximumRetainedPixelBufferBytes == 96 * 1024 * 1024)
        #expect(!policy.usesBufferedPlayout)
    }

    @Test("Presentation latency policy bounds smoothest Wi-Fi playout")
    func presentationLatencyPolicyBoundsSmoothestWiFiPlayout() {
        let policy = MiragePresentationLatencyPolicy(
            latencyMode: .smoothest,
            sourceFPS: 60,
            displayFPS: 120,
            transportPathKind: .wifi,
            hasRecentInteraction: true,
            lastInteractionAgeSeconds: 0.3
        )

        #expect(policy.baseTargetPlayoutDelayMs == 100)
        #expect(policy.minimumTargetPlayoutDelayMs == 60)
        #expect(policy.maximumTargetPlayoutDelayMs == 350)
        #expect(policy.targetPlayoutDelayFrames == MirageMedia.MirageStreamCadenceTarget.defaultPlayoutDelayFrames(for: .smoothest))
        #expect(abs(policy.inputDelayReductionFraction - 0.4) < 0.000_001)
        #expect(abs(policy.effectiveTargetPlayoutDelayMs(adaptedDelayMs: 100) - 60) < 0.000_001)
    }

    @Test("Presentation latency policy clamps AWDL realtime receiver targets")
    func presentationLatencyPolicyClampsAwdlRealtimeReceiverTargets() {
        let policy = MiragePresentationLatencyPolicy(
            latencyMode: .smoothest,
            sourceFPS: 240,
            displayFPS: 240,
            transportPathKind: .awdl,
            mediaPathProfile: .awdlRadio,
            hasRecentInteraction: true,
            lastInteractionAgeSeconds: 0.3,
            awdlReceiverPlayoutDelayTargetMs: .greatestFiniteMagnitude
        )

        #expect(policy.latencyMode == .balanced)
        #expect(policy.sourceFPS == 120)
        #expect(policy.displayFPS == 120)
        #expect(policy.awdlReceiverPlayoutDelayTargetMs == MirageAwdlMediaController.maximumPlayoutDelayMs)
        #expect(policy.usesAwdlRealtimePolicy)
        #expect(policy.usesBufferedPlayout)
        #expect(policy.inputDelayReductionFraction == 0)
        #expect(policy.baseTargetPlayoutDelayMs == MirageAwdlMediaController.maximumPlayoutDelayMs)
        #expect(policy.maximumQueueAgeMs <= MirageAwdlMediaController.maximumReceiverQueueAgeMs)
    }

    @Test("Render cursors compare generations before sequences")
    func renderCursorsCompareGenerationsBeforeSequences() {
        let zero = MirageRenderCursor.zero
        let first = MirageRenderCursor(generation: 1, sequence: 1)
        let laterSequence = MirageRenderCursor(generation: 1, sequence: 2)
        let nextGeneration = MirageRenderCursor(generation: 2, sequence: 0)

        #expect(!zero.hasSubmittedFrame)
        #expect(first.hasSubmittedFrame)
        #expect(laterSequence.isAfter(first))
        #expect(nextGeneration.isAfter(laterSequence))
        #expect(!first.isAfter(nextGeneration))
    }

    @Test("Rendered frame telemetry preserves selected and submitted cursors")
    func renderedFrameTelemetryPreservesSelectedAndSubmittedCursors() {
        let selectedCursor = MirageRenderCursor(generation: 3, sequence: 12)
        let renderedCursor = MirageRenderCursor(generation: 3, sequence: 11)
        let telemetry = MirageRenderedFrameTelemetry(
            streamID: 42,
            selectedCursor: selectedCursor,
            selectedFrameNumber: 120,
            renderedCursor: renderedCursor,
            renderedFrameNumber: 119,
            renderedFrameSubmittedTime: 1_234.5,
            repeatedDisplayTicks: 2,
            droppedForLatency: 3
        )

        #expect(telemetry.streamID == 42)
        #expect(telemetry.selectedCursor == selectedCursor)
        #expect(telemetry.selectedFrameNumber == 120)
        #expect(telemetry.renderedCursor == renderedCursor)
        #expect(telemetry.renderedFrameNumber == 119)
        #expect(telemetry.renderedFrameSubmittedTime == 1_234.5)
        #expect(telemetry.repeatedDisplayTicks == 2)
        #expect(telemetry.droppedForLatency == 3)
    }

    @Test("Render frame presentation metadata normalizes valid content rects")
    func renderFramePresentationMetadataNormalizesValidContentRects() throws {
        let pixelBuffer = try makePixelBuffer(width: 640, height: 360)

        let metadata = MirageRenderFramePresentationMetadata(
            pixelBuffer: pixelBuffer,
            contentRect: CGRect(x: 64, y: 36, width: 320, height: 180)
        )

        #expect(metadata.pixelWidth == 640)
        #expect(metadata.pixelHeight == 360)
        #expect(metadata.pixelFormat == kCVPixelFormatType_32BGRA)
        #expect(metadata.contentReferenceSize == CGSize(width: 320, height: 180))
        #expect(metadata.normalizedContentRect == CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5))
    }

    @Test("Render frame presentation metadata falls back to full-frame content rects")
    func renderFramePresentationMetadataFallsBackToFullFrameContentRects() throws {
        let pixelBuffer = try makePixelBuffer(width: 640, height: 360)

        let metadata = MirageRenderFramePresentationMetadata(
            pixelBuffer: pixelBuffer,
            contentRect: .zero
        )

        #expect(metadata.contentReferenceSize == CGSize(width: 640, height: 360))
        #expect(metadata.normalizedContentRect == CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    @Test("Render frames preserve cursor, presentation, playout, and timeline metadata")
    func renderFramesPreservePresentationAndTimelineMetadata() throws {
        let pixelBuffer = try makePixelBuffer(width: 320, height: 180)
        let decodeTime: CFAbsoluteTime = 1_000
        let presentationTime = CMTime(value: 10, timescale: 60)
        let remotePresentationTime = CMTime(value: 12, timescale: 60)
        let timeline = MirageDiagnostics.FrameTimeline(
            streamID: 7,
            frameNumber: 91,
            dependencyEpoch: MirageDiagnostics.DependencyEpoch(4),
            isKeyframe: true,
            encodedByteCount: 8_192,
            fragmentCount: 3
        )

        let frame = MirageRenderFrame(
            pixelBuffer: pixelBuffer,
            contentRect: CGRect(x: 32, y: 18, width: 160, height: 90),
            sequence: 44,
            generation: 3,
            decodeTime: decodeTime,
            presentationTime: presentationTime,
            remotePresentationTime: remotePresentationTime,
            hostEpoch: 4,
            dimensionToken: 12,
            frameNumber: 91,
            queueEpoch: 2,
            transportPathKind: .wifi,
            targetPlayoutTime: 1_001,
            targetPlayoutDelayMs: -25,
            timeline: timeline
        )
        let updated = frame.withPlayoutMetadata(
            transportPathKind: .awdl,
            targetPlayoutTime: 1_002,
            targetPlayoutDelayMs: 45
        )

        #expect(frame.sequence == 44)
        #expect(frame.cursor == MirageRenderCursor(generation: 3, sequence: 44))
        #expect(frame.presentationMetadata.normalizedContentRect == CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5))
        #expect(frame.targetPlayoutDelayMs == 0)
        #expect(frame.timeline == timeline)
        #expect(updated.pixelBuffer === pixelBuffer)
        #expect(updated.transportPathKind == .awdl)
        #expect(updated.targetPlayoutTime == 1_002)
        #expect(updated.targetPlayoutDelayMs == 45)
        #expect(updated.timeline == timeline)
        #expect(updated.presentationTime == presentationTime)
        #expect(updated.remotePresentationTime == remotePresentationTime)
    }

    @Test("Video playout buffer coalesces lowest-latency frames")
    func videoPlayoutBufferCoalescesLowestLatencyFrames() throws {
        let now: CFAbsoluteTime = 2_000
        let policy = MiragePresentationLatencyPolicy(
            latencyMode: .lowestLatency,
            sourceFPS: 60,
            displayFPS: 60
        )
        var buffer = MirageVideoPlayoutBuffer()
        var frames: [MirageRenderFrame] = []

        _ = buffer.enqueue(
            try makeRenderFrame(sequence: 1, decodeTime: now),
            into: &frames,
            policy: policy,
            now: now
        )
        let trim = buffer.enqueue(
            try makeRenderFrame(sequence: 2, decodeTime: now + 0.010),
            into: &frames,
            policy: policy,
            now: now + 0.010
        )
        let selection = buffer.selectFrame(
            frames: &frames,
            after: .zero,
            policy: policy,
            now: now + 0.012
        )

        #expect(trim.overwrittenPendingFrames == 1)
        #expect(trim.coalescedFrames == 1)
        #expect(selection.frame?.sequence == 2)
        #expect(selection.selectedFrameNumber == 2)
        #expect(selection.trimResult == .empty)
        #expect(selection.frame?.targetPlayoutTime == nil)
        #expect(selection.frame?.targetPlayoutDelayMs == 0)
    }

    @Test("Presentation controller preserves buffered playout hold")
    func presentationControllerPreservesBufferedPlayoutHold() throws {
        let now: CFAbsoluteTime = 3_000
        let policy = MiragePresentationLatencyPolicy(
            latencyMode: .balanced,
            sourceFPS: 60,
            displayFPS: 60
        )
        var controller = MirageClientPresentationController()
        var frames: [MirageRenderFrame] = []

        _ = controller.enqueue(
            try makeRenderFrame(sequence: 1, decodeTime: now),
            into: &frames,
            policy: policy,
            now: now
        )
        let heldSelection = controller.nextFrame(
            frames: &frames,
            after: .zero,
            policy: policy,
            now: now
        )
        let readySelection = controller.nextFrame(
            frames: &frames,
            after: .zero,
            policy: policy,
            now: now + 0.040
        )

        #expect(heldSelection.frame == nil)
        #expect(frames.count == 1)
        #expect(readySelection.frame?.sequence == 1)
        #expect(readySelection.frame?.targetPlayoutDelayMs ?? 0 > 0)
        #expect(controller.smoothestTargetDelayMs(policy: policy) > 0)
    }

    @Test("Desktop presentation geometry maps through aspect-fit content rects")
    func desktopPresentationGeometryMapsThroughAspectFitContentRects() {
        let bounds = CGRect(x: 0, y: 0, width: 1600, height: 900)
        let contentRect = DesktopPresentationGeometry.resolvedContentRect(
            referenceSize: CGSize(width: 1280, height: 800),
            in: bounds
        )

        #expect(contentRect == CGRect(x: 80, y: 0, width: 1440, height: 900))
        #expect(
            DesktopPresentationGeometry.normalizedPosition(
                for: CGPoint(x: 20, y: 450),
                in: contentRect
            ) == CGPoint(x: 0, y: 0.5)
        )
        #expect(
            DesktopPresentationGeometry.localPoint(
                for: CGPoint(x: 0.25, y: 0.75),
                in: contentRect
            ) == CGPoint(x: 440, y: 225)
        )
        #expect(
            DesktopPresentationGeometry.clampedNormalizedPosition(
                CGPoint(x: -1, y: 2)
            ) == CGPoint(x: 0, y: 1)
        )
    }

    @Test("Stream presentation policy resolves container sizing")
    func streamPresentationPolicyResolvesContainerSizing() {
        let boundsSize = CGSize(width: 1234, height: 710)
        let contentLayoutSize = CGSize(width: 1234, height: 678)

        #expect(
            MirageStreamPresentationPolicy.containerSize(
                boundsSize: boundsSize,
                contentLayoutSize: contentLayoutSize,
                mode: .viewBounds
            ) == boundsSize
        )
        #expect(
            MirageStreamPresentationPolicy.containerSize(
                boundsSize: boundsSize,
                contentLayoutSize: contentLayoutSize,
                mode: .contentLayout
            ) == contentLayoutSize
        )
        #expect(
            MirageStreamPresentationPolicy.localAspectFitReferenceSize(
                prefersLocalAspectFitPresentation: false,
                hostDisplayPointSize: contentLayoutSize
            ) == nil
        )
        #expect(
            MirageStreamPresentationPolicy.localAspectFitReferenceSize(
                prefersLocalAspectFitPresentation: true,
                hostDisplayPointSize: contentLayoutSize
            ) == contentLayoutSize
        )
    }

    @Test("Stream presentation policy suppresses local resize for host-owned desktop or keyboard occlusion")
    func streamPresentationPolicySuppressesLocalResizeForHostOwnedDesktopOrKeyboardOcclusion() {
        #expect(
            MirageStreamPresentationPolicy.suppressesWindowDrivenResizeForLocalPresentation(
                isDesktopStream: true,
                useHostResolution: true,
                desktopCaptureSource: .virtualDisplay,
                desktopStreamAllowsClientResize: true,
                keyboardAvoidanceEnabled: false,
                softwareKeyboardVisible: false,
                localKeyboardOcclusionActive: false
            )
        )
        #expect(
            MirageStreamPresentationPolicy.suppressesWindowDrivenResizeForLocalPresentation(
                isDesktopStream: false,
                useHostResolution: false,
                desktopCaptureSource: .virtualDisplay,
                desktopStreamAllowsClientResize: true,
                keyboardAvoidanceEnabled: true,
                softwareKeyboardVisible: false,
                localKeyboardOcclusionActive: true
            )
        )
        #expect(
            MirageStreamPresentationPolicy.suppressesWindowDrivenResizeForLocalPresentation(
                isDesktopStream: true,
                useHostResolution: false,
                desktopCaptureSource: .mainDisplayFallback,
                desktopStreamAllowsClientResize: true,
                keyboardAvoidanceEnabled: false,
                softwareKeyboardVisible: false,
                localKeyboardOcclusionActive: false
            )
        )
        #expect(
            MirageStreamPresentationPolicy.suppressesWindowDrivenResizeForLocalPresentation(
                isDesktopStream: true,
                useHostResolution: false,
                desktopCaptureSource: .virtualDisplay,
                desktopStreamAllowsClientResize: false,
                keyboardAvoidanceEnabled: false,
                softwareKeyboardVisible: false,
                localKeyboardOcclusionActive: false
            )
        )
        #expect(
            !MirageStreamPresentationPolicy.suppressesWindowDrivenResizeForLocalPresentation(
                isDesktopStream: true,
                useHostResolution: false,
                desktopCaptureSource: .virtualDisplay,
                desktopStreamAllowsClientResize: true,
                keyboardAvoidanceEnabled: false,
                softwareKeyboardVisible: false,
                localKeyboardOcclusionActive: false
            )
        )
    }

    private func makePixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            nil,
            &pixelBuffer
        )
        #expect(status == kCVReturnSuccess)
        return try #require(pixelBuffer)
    }

    private func makeRenderFrame(sequence: UInt64, decodeTime: CFAbsoluteTime) throws -> MirageRenderFrame {
        MirageRenderFrame(
            pixelBuffer: try makePixelBuffer(width: 16, height: 16),
            contentRect: .zero,
            sequence: sequence,
            decodeTime: decodeTime,
            presentationTime: CMTime(value: CMTimeValue(sequence), timescale: 60),
            remotePresentationTime: CMTime(value: CMTimeValue(sequence), timescale: 60),
            frameNumber: UInt32(sequence)
        )
    }
}
