//
//  RenderCadenceSmoothingTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/17/26.
//
//  Coverage for latency-mode render cadence behavior.
//

@testable import MirageKitClient
import CoreMedia
import CoreVideo
import Foundation
import MirageKit
import MirageKitClientPresentation
import Testing
import MirageCore
import MirageMedia

#if os(macOS)
@Suite("Render Cadence Smoothing")
struct RenderCadenceSmoothingTests {
    @Test("Smoothest render store keeps an ordered bounded playout queue")
    func smoothestRenderStoreKeepsOrderedBoundedPlayoutQueue() {
        let streamID: StreamID = 401
        MirageRenderStreamStore.shared.clear(for: streamID)
        defer { MirageRenderStreamStore.shared.clear(for: streamID) }
        MirageRenderStreamStore.shared.setLatencyMode(for: streamID, latencyMode: .smoothest)

        for index in 0 ..< 9 {
            _ = MirageRenderStreamStore.shared.enqueue(
                pixelBuffer: makePixelBuffer(),
                contentRect: .zero,
                decodeTime: Double(index),
                presentationTime: CMTime(seconds: Double(index), preferredTimescale: 600),
                for: streamID
            )
        }

        #expect(MirageRenderStreamStore.shared.pendingFrameCount(for: streamID) == 9)
        #expect(MirageRenderStreamStore.shared.peekPendingFrame(for: streamID)?.sequence == 1)

        let telemetry = MirageRenderStreamStore.shared.renderTelemetrySnapshot(for: streamID)
        #expect(telemetry.pendingFrameCount == 9)
        #expect(telemetry.overwrittenPendingFrames == 0)
        #expect(telemetry.smoothestQueueDrops == 0)
        #expect(telemetry.coalescedBeforeSubmitCount == 0)
        #expect(telemetry.playoutDelayFrames == 4)
    }

    @Test("Smoothest ProMotion render store keeps a bounded FIFO playout queue")
    func smoothestProMotionRenderStoreKeepsBoundedFIFOQueue() {
        let streamID: StreamID = 406
        MirageRenderStreamStore.shared.clear(for: streamID)
        defer { MirageRenderStreamStore.shared.clear(for: streamID) }
        MirageRenderStreamStore.shared.setCadenceTarget(
            for: streamID,
            target: MirageMedia.MirageStreamCadenceTarget(
                sourceFPS: 120,
                displayFPS: 120,
                latencyMode: .smoothest
            )
        )

        for index in 0 ..< 13 {
            _ = MirageRenderStreamStore.shared.enqueue(
                pixelBuffer: makePixelBuffer(),
                contentRect: .zero,
                decodeTime: Double(index),
                presentationTime: CMTime(seconds: Double(index), preferredTimescale: 600),
                for: streamID
            )
        }

        #expect(MirageRenderStreamStore.shared.pendingFrameCount(for: streamID) == 13)
        #expect(MirageRenderStreamStore.shared.peekPendingFrame(for: streamID)?.sequence == 1)

        let telemetry = MirageRenderStreamStore.shared.renderTelemetrySnapshot(for: streamID)
        #expect(telemetry.pendingFrameCount == 13)
        #expect(telemetry.smoothestQueueDrops == 0)
        #expect(telemetry.playoutDelayFrames == 4)
    }

    @Test("Smoothest holds the first frame until its playout target")
    func smoothestHoldsFirstFrameUntilItsPlayoutTarget() {
        let streamID: StreamID = 407
        MirageRenderStreamStore.shared.clear(for: streamID)
        defer { MirageRenderStreamStore.shared.clear(for: streamID) }
        MirageRenderStreamStore.shared.setTransportPathKind(for: streamID, pathKind: .wifi)
        MirageRenderStreamStore.shared.setCadenceTarget(
            for: streamID,
            target: MirageMedia.MirageStreamCadenceTarget(
                sourceFPS: 60,
                displayFPS: 60,
                latencyMode: .smoothest
            )
        )

        _ = MirageRenderStreamStore.shared.enqueue(
            pixelBuffer: makePixelBuffer(),
            contentRect: .zero,
            decodeTime: CFAbsoluteTimeGetCurrent(),
            presentationTime: .zero,
            for: streamID
        )
        let first = MirageRenderStreamStore.shared.frameForPresentation(for: streamID, after: .zero)
        #expect(first == nil)
        #expect(MirageRenderStreamStore.shared.peekPendingFrame(for: streamID)?.targetPlayoutDelayMs == 100)

        let telemetry = MirageRenderStreamStore.shared.renderTelemetrySnapshot(for: streamID)
        #expect(telemetry.playoutDelayFrames == 4)
    }

    @Test("Smoothest drops stale backlog before presenting a fresh frame")
    func smoothestDropsStaleBacklogBeforePresentingFreshFrame() {
        let streamID: StreamID = 408
        MirageRenderStreamStore.shared.clear(for: streamID)
        defer { MirageRenderStreamStore.shared.clear(for: streamID) }
        MirageRenderStreamStore.shared.setCadenceTarget(
            for: streamID,
            target: MirageMedia.MirageStreamCadenceTarget(
                sourceFPS: 60,
                displayFPS: 60,
                latencyMode: .smoothest
            )
        )

        let now = CFAbsoluteTimeGetCurrent()
        for index in 0 ..< 3 {
            let age: CFAbsoluteTime = index < 2 ? 0.650 : 0.050
            _ = MirageRenderStreamStore.shared.enqueue(
                pixelBuffer: makePixelBuffer(),
                contentRect: .zero,
                decodeTime: now - age,
                presentationTime: CMTime(value: CMTimeValue(index), timescale: 60),
                for: streamID
            )
        }

        let frame = MirageRenderStreamStore.shared.frameForPresentation(for: streamID, after: .zero)
        #expect(frame == nil)
        #expect(MirageRenderStreamStore.shared.peekPendingFrame(for: streamID)?.sequence == 3)

        let telemetry = MirageRenderStreamStore.shared.renderTelemetrySnapshot(for: streamID)
        #expect(telemetry.smoothestQueueDrops == 2)
        #expect(telemetry.pendingFrameCount == 1)
    }

    @Test("Smoothest keeps normal 60Hz jitter instead of dropping it")
    func smoothestKeepsNormalSixtyHertzJitter() {
        let streamID: StreamID = 409
        MirageRenderStreamStore.shared.clear(for: streamID)
        defer { MirageRenderStreamStore.shared.clear(for: streamID) }
        MirageRenderStreamStore.shared.setCadenceTarget(
            for: streamID,
            target: MirageMedia.MirageStreamCadenceTarget(
                sourceFPS: 60,
                displayFPS: 60,
                latencyMode: .smoothest
            )
        )

        let now = CFAbsoluteTimeGetCurrent()
        for age in [0.035, 0.030, 0.025] {
            _ = MirageRenderStreamStore.shared.enqueue(
                pixelBuffer: makePixelBuffer(),
                contentRect: .zero,
                decodeTime: now - age,
                presentationTime: CMTime(seconds: age, preferredTimescale: 600),
                for: streamID
            )
        }

        let frame = MirageRenderStreamStore.shared.frameForPresentation(for: streamID, after: .zero)
        #expect(frame == nil)

        let telemetry = MirageRenderStreamStore.shared.renderTelemetrySnapshot(for: streamID)
        #expect(telemetry.smoothestQueueDrops == 0)
        #expect(telemetry.pendingFrameCount == 3)
    }

    @Test("Smoothest uses path-specific initial playout targets")
    func smoothestUsesPathSpecificInitialPlayoutTargets() {
        let streamID: StreamID = 412
        for (pathKind, expectedDelayMs) in [
            (MirageCore.MirageNetworkPathKind.wired, 50.0),
            (.wifi, 100.0),
            (.awdl, MirageAwdlMediaController.basePlayoutDelayMs),
            (.vpn, 250.0),
        ] {
            MirageRenderStreamStore.shared.clear(for: streamID)
            MirageRenderStreamStore.shared.setTransportPathKind(for: streamID, pathKind: pathKind)
            MirageRenderStreamStore.shared.setCadenceTarget(
                for: streamID,
                target: MirageMedia.MirageStreamCadenceTarget(
                    sourceFPS: 60,
                    displayFPS: 60,
                    latencyMode: .smoothest
                )
            )
            _ = MirageRenderStreamStore.shared.enqueue(
                pixelBuffer: makePixelBuffer(),
                contentRect: .zero,
                decodeTime: CFAbsoluteTimeGetCurrent(),
                presentationTime: .zero,
                for: streamID
            )
            #expect(MirageRenderStreamStore.shared.peekPendingFrame(for: streamID)?.targetPlayoutDelayMs == expectedDelayMs)
        }
        MirageRenderStreamStore.shared.clear(for: streamID)
    }

    @Test("Path-only AWDL uses realtime radio playout")
    func pathOnlyAwdlUsesRealtimeRadioPlayout() {
        let streamID: StreamID = 413
        MirageRenderStreamStore.shared.clear(for: streamID)
        defer { MirageRenderStreamStore.shared.clear(for: streamID) }
        MirageRenderStreamStore.shared.setTransportPathKind(for: streamID, pathKind: .awdl)
        MirageRenderStreamStore.shared.setCadenceTarget(
            for: streamID,
            target: MirageMedia.MirageStreamCadenceTarget(
                sourceFPS: 60,
                displayFPS: 60,
                latencyMode: .smoothest
            )
        )
        MirageRenderStreamStore.shared.noteInteraction(for: streamID, now: CFAbsoluteTimeGetCurrent() - 0.300)

        _ = MirageRenderStreamStore.shared.enqueue(
            pixelBuffer: makePixelBuffer(),
            contentRect: .zero,
            decodeTime: CFAbsoluteTimeGetCurrent(),
            presentationTime: .zero,
            for: streamID
        )

        let targetDelayMs = MirageRenderStreamStore.shared.peekPendingFrame(for: streamID)?.targetPlayoutDelayMs ?? 0
        #expect(targetDelayMs == MirageAwdlMediaController.basePlayoutDelayMs)
    }

    @Test("Balanced Wi-Fi uses two-frame playout hold and immediate display timing")
    func balancedWifiUsesTwoFramePlayoutHoldAndImmediateDisplayTiming() {
        let streamID: StreamID = 414
        MirageRenderStreamStore.shared.clear(for: streamID)
        defer { MirageRenderStreamStore.shared.clear(for: streamID) }
        MirageRenderStreamStore.shared.setTransportPathKind(for: streamID, pathKind: .wifi)
        MirageRenderStreamStore.shared.setCadenceTarget(
            for: streamID,
            target: MirageMedia.MirageStreamCadenceTarget(
                sourceFPS: 60,
                displayFPS: 60,
                latencyMode: .balanced
            )
        )

        _ = MirageRenderStreamStore.shared.enqueue(
            pixelBuffer: makePixelBuffer(),
            contentRect: .zero,
            decodeTime: CFAbsoluteTimeGetCurrent(),
            presentationTime: .zero,
            for: streamID
        )

        let pendingDelayMs = MirageRenderStreamStore.shared.peekPendingFrame(for: streamID)?.targetPlayoutDelayMs
        #expect(abs((pendingDelayMs ?? 0) - (1000.0 / 60.0 * 2.0)) < 0.001)

        let timing = MirageRenderStreamStore.shared.presentationTiming(for: streamID)
        #expect(timing.latencyMode == .balanced)
        #expect(timing.displaysImmediately)
    }

    @Test("AWDL radio uses buffered realtime playout")
    func awdlRadioUsesBufferedRealtimePlayout() {
        let streamID: StreamID = 416
        MirageRenderStreamStore.shared.clear(for: streamID)
        defer { MirageRenderStreamStore.shared.clear(for: streamID) }
        MirageRenderStreamStore.shared.setTransportPathKind(for: streamID, pathKind: .awdl)
        MirageRenderStreamStore.shared.setMediaPathProfile(for: streamID, profile: .awdlRadio)
        MirageRenderStreamStore.shared.setCadenceTarget(
            for: streamID,
            target: MirageMedia.MirageStreamCadenceTarget(
                sourceFPS: 60,
                displayFPS: 60,
                latencyMode: .lowestLatency
            )
        )

        _ = MirageRenderStreamStore.shared.enqueue(
            pixelBuffer: makePixelBuffer(),
            contentRect: .zero,
            decodeTime: CFAbsoluteTimeGetCurrent(),
            presentationTime: .zero,
            for: streamID
        )

        #expect(MirageRenderStreamStore.shared.frameForPresentation(for: streamID, after: .zero) == nil)
        #expect(
            MirageRenderStreamStore.shared.peekPendingFrame(for: streamID)?.targetPlayoutDelayMs ==
                MirageAwdlMediaController.basePlayoutDelayMs
        )
        let timing = MirageRenderStreamStore.shared.presentationTiming(for: streamID)
        #expect(timing.latencyMode == .balanced)
        #expect(!timing.displaysImmediately)
    }

    @Test("AWDL path kind without media profile uses fixed realtime playout")
    func awdlPathKindWithoutMediaProfileUsesFixedRealtimePlayout() {
        let streamID: StreamID = 419
        MirageRenderStreamStore.shared.clear(for: streamID)
        defer { MirageRenderStreamStore.shared.clear(for: streamID) }
        MirageRenderStreamStore.shared.setTransportPathKind(for: streamID, pathKind: .awdl)
        MirageRenderStreamStore.shared.setCadenceTarget(
            for: streamID,
            target: MirageMedia.MirageStreamCadenceTarget(
                sourceFPS: 60,
                displayFPS: 60,
                latencyMode: .lowestLatency
            )
        )

        let timing = MirageRenderStreamStore.shared.presentationTiming(for: streamID)

        #expect(timing.latencyMode == .balanced)
        #expect(timing.usesFixedRealtimeDisplayPolicy)
        #expect(!timing.displaysImmediately)
        #expect(timing.playoutDelayFrames >= 2)
    }

    @Test("AWDL path kind with other profile uses fixed realtime playout")
    func awdlPathKindWithOtherProfileUsesFixedRealtimePlayout() {
        let streamID: StreamID = 420
        MirageRenderStreamStore.shared.clear(for: streamID)
        defer { MirageRenderStreamStore.shared.clear(for: streamID) }
        MirageRenderStreamStore.shared.setTransportPathKind(for: streamID, pathKind: .awdl)
        MirageRenderStreamStore.shared.setMediaPathProfile(for: streamID, profile: .other)
        MirageRenderStreamStore.shared.setCadenceTarget(
            for: streamID,
            target: MirageMedia.MirageStreamCadenceTarget(
                sourceFPS: 60,
                displayFPS: 60,
                latencyMode: .lowestLatency
            )
        )

        let timing = MirageRenderStreamStore.shared.presentationTiming(for: streamID)

        #expect(timing.latencyMode == .balanced)
        #expect(timing.usesFixedRealtimeDisplayPolicy)
        #expect(!timing.displaysImmediately)
        #expect(timing.playoutDelayFrames >= 2)
    }

    @Test("AWDL path kind with proximity wired profile keeps immediate presentation")
    func awdlPathKindWithProximityWiredProfileKeepsImmediatePresentation() {
        let streamID: StreamID = 421
        MirageRenderStreamStore.shared.clear(for: streamID)
        defer { MirageRenderStreamStore.shared.clear(for: streamID) }
        MirageRenderStreamStore.shared.setTransportPathKind(for: streamID, pathKind: .awdl)
        MirageRenderStreamStore.shared.setMediaPathProfile(for: streamID, profile: .proximityWiredLike)
        MirageRenderStreamStore.shared.setCadenceTarget(
            for: streamID,
            target: MirageMedia.MirageStreamCadenceTarget(
                sourceFPS: 120,
                displayFPS: 120,
                latencyMode: .lowestLatency
            )
        )

        let timing = MirageRenderStreamStore.shared.presentationTiming(for: streamID)

        #expect(timing.latencyMode == .lowestLatency)
        #expect(!timing.usesFixedRealtimeDisplayPolicy)
        #expect(timing.displaysImmediately)
    }

    @Test("AWDL receiver pressure raises local playout target before underfill")
    func awdlReceiverPressureRaisesLocalPlayoutTargetBeforeUnderfill() {
        let streamID: StreamID = 417
        MirageRenderStreamStore.shared.clear(for: streamID)
        defer { MirageRenderStreamStore.shared.clear(for: streamID) }
        MirageRenderStreamStore.shared.setTransportPathKind(for: streamID, pathKind: .awdl)
        MirageRenderStreamStore.shared.setMediaPathProfile(for: streamID, profile: .awdlRadio)
        MirageRenderStreamStore.shared.setCadenceTarget(
            for: streamID,
            target: MirageMedia.MirageStreamCadenceTarget(
                sourceFPS: 60,
                displayFPS: 60,
                latencyMode: .lowestLatency
            )
        )
        MirageRenderStreamStore.shared.updateAwdlReceiverPlayoutTarget(
            for: streamID,
            targetFPS: 60,
            receiverJitterP99Ms: 160,
            presentationStallCount: 0
        )

        _ = MirageRenderStreamStore.shared.enqueue(
            pixelBuffer: makePixelBuffer(),
            contentRect: .zero,
            decodeTime: CFAbsoluteTimeGetCurrent(),
            presentationTime: .zero,
            for: streamID
        )

        #expect(
            MirageRenderStreamStore.shared.peekPendingFrame(for: streamID)?.targetPlayoutDelayMs ==
                MirageAwdlMediaController.stableMaximumPlayoutDelayMs
        )
        let telemetry = MirageRenderStreamStore.shared.renderTelemetrySnapshot(for: streamID)
        #expect(telemetry.smoothestTargetDelayMs == MirageAwdlMediaController.stableMaximumPlayoutDelayMs)
        #expect(telemetry.playoutDelayFrames == 5)
    }

    @Test("AWDL completed receive gaps do not raise local playout without ingress jitter")
    func awdlCompletedReceiveGapsDoNotRaiseLocalPlayoutWithoutIngressJitter() {
        let streamID: StreamID = 418
        MirageRenderStreamStore.shared.clear(for: streamID)
        defer { MirageRenderStreamStore.shared.clear(for: streamID) }
        MirageRenderStreamStore.shared.setTransportPathKind(for: streamID, pathKind: .awdl)
        MirageRenderStreamStore.shared.setMediaPathProfile(for: streamID, profile: .awdlRadio)
        MirageRenderStreamStore.shared.setCadenceTarget(
            for: streamID,
            target: MirageMedia.MirageStreamCadenceTarget(
                sourceFPS: 60,
                displayFPS: 60,
                latencyMode: .lowestLatency
            )
        )
        MirageRenderStreamStore.shared.updateAwdlReceiverPlayoutTarget(
            for: streamID,
            targetFPS: 60,
            presentationStallCount: 0
        )

        _ = MirageRenderStreamStore.shared.enqueue(
            pixelBuffer: makePixelBuffer(),
            contentRect: .zero,
            decodeTime: CFAbsoluteTimeGetCurrent(),
            presentationTime: .zero,
            for: streamID
        )

        #expect(
            MirageRenderStreamStore.shared.peekPendingFrame(for: streamID)?.targetPlayoutDelayMs ==
                MirageAwdlMediaController.basePlayoutDelayMs
        )
        let telemetry = MirageRenderStreamStore.shared.renderTelemetrySnapshot(for: streamID)
        #expect(telemetry.smoothestTargetDelayMs == MirageAwdlMediaController.basePlayoutDelayMs)
        #expect(telemetry.playoutDelayFrames == 2)
    }

    @Test("AWDL presentation latency policy accepts receiver target")
    func awdlPresentationLatencyPolicyAcceptsReceiverTarget() {
        let policy = MiragePresentationLatencyPolicy(
            latencyMode: .lowestLatency,
            sourceFPS: 60,
            displayFPS: 60,
            transportPathKind: .awdl,
            mediaPathProfile: .awdlRadio,
            awdlReceiverPlayoutDelayTargetMs: 96
        )

        #expect(policy.baseTargetPlayoutDelayMs == 96)
        #expect(policy.targetPlayoutDelayFrames == 6)
    }

    @Test("AWDL presentation policy does not reduce receiver playout target twice for input")
    func awdlPresentationPolicyDoesNotReduceReceiverPlayoutTargetTwiceForInput() {
        let policy = MiragePresentationLatencyPolicy(
            latencyMode: .lowestLatency,
            sourceFPS: 60,
            displayFPS: 60,
            transportPathKind: .awdl,
            mediaPathProfile: .awdlRadio,
            hasRecentInteraction: true,
            lastInteractionAgeSeconds: 0.400,
            awdlReceiverPlayoutDelayTargetMs: 80
        )

        #expect(policy.inputDelayReductionFraction == 0)
        #expect(policy.effectiveTargetPlayoutDelayMs(adaptedDelayMs: policy.baseTargetPlayoutDelayMs) == 80)
        #expect(policy.targetPlayoutDelayFrames == 5)
    }

    @Test("AWDL receiver policy caps stale local backlog below legacy smoothest window")
    func awdlReceiverPolicyCapsStaleLocalBacklogBelowLegacySmoothestWindow() {
        let policy = MiragePresentationLatencyPolicy(
            latencyMode: .lowestLatency,
            sourceFPS: 60,
            displayFPS: 60,
            transportPathKind: .awdl,
            mediaPathProfile: .awdlRadio,
            awdlReceiverPlayoutDelayTargetMs: MirageAwdlMediaController.maximumPlayoutDelayMs
        )

        #expect(policy.maximumQueueAgeMs < 300)
        #expect(policy.maximumQueueAgeMs <= MirageAwdlMediaController.maximumReceiverQueueAgeMs)
        #expect(policy.smoothestDisplayDebtCapMs <= MirageAwdlMediaController.maximumReceiverDisplayDebtMs)
        #expect(policy.hardResetDebtMs <= MirageAwdlMediaController.maximumReceiverHardResetDebtMs)
    }

    @Test("AWDL drops stale local backlog even when target playout is still future")
    func awdlDropsStaleLocalBacklogEvenWhenTargetPlayoutIsStillFuture() {
        let policy = MiragePresentationLatencyPolicy(
            latencyMode: .lowestLatency,
            sourceFPS: 60,
            displayFPS: 60,
            transportPathKind: .awdl,
            mediaPathProfile: .awdlRadio,
            awdlReceiverPlayoutDelayTargetMs: MirageAwdlMediaController.maximumPlayoutDelayMs
        )
        let now = CFAbsoluteTimeGetCurrent()
        var buffer = MirageVideoPlayoutBuffer()
        var frames = makeRenderFrames(count: 4, decodeTime: now - 0.215).map {
            $0.withPlayoutMetadata(
                transportPathKind: .awdl,
                targetPlayoutTime: now + 0.120,
                targetPlayoutDelayMs: MirageAwdlMediaController.maximumPlayoutDelayMs
            )
        }

        let selection = buffer.selectFrame(
            frames: &frames,
            after: .zero,
            policy: policy,
            now: now
        )

        #expect(selection.frame == nil)
        #expect(selection.trimResult.smoothestAgeDrops == 3)
        #expect(selection.trimResult.smoothestDisplayDebtDrops == 0)
        #expect(selection.trimResult.smoothestFifoResetCount == 1)
        #expect(frames.count == 1)
    }

    @Test("AWDL underfill grows adaptive playout delay")
    func awdlUnderfillGrowsAdaptivePlayoutDelay() throws {
        let policy = MiragePresentationLatencyPolicy(
            latencyMode: .lowestLatency,
            sourceFPS: 60,
            displayFPS: 60,
            transportPathKind: .awdl,
            mediaPathProfile: .awdlRadio
        )
        var buffer = MirageVideoPlayoutBuffer()
        let now = CFAbsoluteTimeGetCurrent()
        var frames = [makeRenderFrames(count: 1, decodeTime: now)[0]]

        _ = buffer.enqueue(frames.removeFirst(), into: &frames, policy: policy, now: now)
        let firstSelection = buffer.selectFrame(
            frames: &frames,
            after: .zero,
            policy: policy,
            now: now + 0.060
        )
        let first = try #require(firstSelection.frame)
        frames.removeAll()

        buffer.recordDisplayTickWithoutFrame(policy: policy, now: now + 0.080)
        let next = MirageRenderFrame(
            pixelBuffer: makePixelBuffer(),
            contentRect: .zero,
            sequence: first.sequence + 1,
            decodeTime: now + 0.085,
            presentationTime: CMTime(value: 1, timescale: 60),
            remotePresentationTime: .invalid
        )
        _ = buffer.enqueue(next, into: &frames, policy: policy, now: now + 0.085)

        let delayMs = try #require(frames.first?.targetPlayoutDelayMs)
        #expect(delayMs >= 48)
        #expect(delayMs <= MirageAwdlMediaController.maximumPlayoutDelayMs)
    }

    @Test("AWDL playout hold is not reported as pending-not-ready underflow")
    func awdlPlayoutHoldIsNotReportedAsPendingNotReadyUnderflow() {
        let streamID: StreamID = 422
        MirageRenderStreamStore.shared.clear(for: streamID)
        defer { MirageRenderStreamStore.shared.clear(for: streamID) }
        MirageRenderStreamStore.shared.setTransportPathKind(for: streamID, pathKind: .awdl)
        MirageRenderStreamStore.shared.setMediaPathProfile(for: streamID, profile: .awdlRadio)
        MirageRenderStreamStore.shared.setCadenceTarget(
            for: streamID,
            target: MirageMedia.MirageStreamCadenceTarget(
                sourceFPS: 60,
                displayFPS: 60,
                latencyMode: .lowestLatency
            )
        )

        _ = MirageRenderStreamStore.shared.enqueue(
            pixelBuffer: makePixelBuffer(),
            contentRect: .zero,
            decodeTime: CFAbsoluteTimeGetCurrent(),
            presentationTime: .zero,
            for: streamID
        )

        #expect(MirageRenderStreamStore.shared.frameForPresentation(for: streamID, after: .zero) == nil)
        MirageRenderStreamStore.shared.notePendingFrameNotReadyDisplayTick(for: streamID)

        let telemetry = MirageRenderStreamStore.shared.renderTelemetrySnapshot(for: streamID)
        #expect(telemetry.pendingFrameNotReadyDisplayTickCount == 0)
        #expect(telemetry.pendingFrameCount == 1)
    }

    @Test("AWDL does not use balanced recovery freshest fallback")
    func awdlDoesNotUseBalancedRecoveryFreshestFallback() {
        let policy = MiragePresentationLatencyPolicy(
            latencyMode: .lowestLatency,
            sourceFPS: 60,
            displayFPS: 60,
            transportPathKind: .awdl,
            mediaPathProfile: .awdlRadio
        )
        let now = CFAbsoluteTimeGetCurrent()
        var buffer = MirageVideoPlayoutBuffer()
        var frames = makeRenderFrames(count: 1, decodeTime: now).map {
            $0.withPlayoutMetadata(
                transportPathKind: .awdl,
                targetPlayoutTime: now + 0.200,
                targetPlayoutDelayMs: MirageAwdlMediaController.basePlayoutDelayMs
            )
        }

        let selection = buffer.selectFrame(
            frames: &frames,
            after: .zero,
            policy: policy,
            now: now
        )

        #expect(selection.frame == nil)
        #expect(selection.trimResult.smoothestFifoResetCount == 0)
        #expect(frames.count == 1)
    }

    @Test("AWDL blocks balanced recovery fallback with queued future frames")
    func awdlBlocksBalancedRecoveryFallbackWithQueuedFutureFrames() {
        let policy = MiragePresentationLatencyPolicy(
            latencyMode: .lowestLatency,
            sourceFPS: 60,
            displayFPS: 60,
            transportPathKind: .awdl,
            mediaPathProfile: .awdlRadio
        )
        let now = CFAbsoluteTimeGetCurrent()
        var buffer = MirageVideoPlayoutBuffer()
        var frames = makeRenderFrames(count: 4, decodeTime: now - 0.180).map {
            $0.withPlayoutMetadata(
                transportPathKind: .awdl,
                targetPlayoutTime: now + 0.120,
                targetPlayoutDelayMs: MirageAwdlMediaController.basePlayoutDelayMs
            )
        }

        let selection = buffer.selectFrame(
            frames: &frames,
            after: .zero,
            policy: policy,
            now: now
        )

        #expect(selection.frame == nil)
        #expect(selection.trimResult.smoothestFifoResetCount == 0)
        #expect(frames.count == 4)
    }

    @Test("AWDL path kind with unknown profile still uses AWDL playout policy")
    func awdlPathKindWithUnknownProfileStillUsesAwdlPlayoutPolicy() {
        let policy = MiragePresentationLatencyPolicy(
            latencyMode: .lowestLatency,
            sourceFPS: 60,
            displayFPS: 60,
            transportPathKind: .awdl,
            mediaPathProfile: .unknown
        )

        #expect(policy.mediaPathProfile == .awdlRadio)
        #expect(policy.latencyMode == .balanced)
        #expect(policy.usesBufferedPlayout)
        #expect(policy.baseTargetPlayoutDelayMs == MirageAwdlMediaController.basePlayoutDelayMs)
    }

    @Test("AWDL path kind with proximity wired profile does not use AWDL playout policy")
    func awdlPathKindWithProximityWiredProfileDoesNotUseAwdlPlayoutPolicy() {
        let policy = MiragePresentationLatencyPolicy(
            latencyMode: .lowestLatency,
            sourceFPS: 120,
            displayFPS: 120,
            transportPathKind: .awdl,
            mediaPathProfile: .proximityWiredLike
        )

        #expect(policy.mediaPathProfile == .proximityWiredLike)
        #expect(policy.latencyMode == .lowestLatency)
        #expect(!policy.usesAwdlRealtimePolicy)
        #expect(!policy.usesBufferedPlayout)
        #expect(policy.targetPlayoutDelayFrames == 0)
    }

    @Test("AWDL path kind with smoothest unknown profile still resolves AWDL playout policy")
    func awdlPathKindWithSmoothestUnknownProfileStillResolvesAwdlPlayoutPolicy() {
        let policy = MiragePresentationLatencyPolicy(
            latencyMode: .smoothest,
            sourceFPS: 60,
            displayFPS: 60,
            transportPathKind: .awdl,
            mediaPathProfile: .unknown
        )

        #expect(policy.mediaPathProfile == .awdlRadio)
        #expect(policy.latencyMode == .balanced)
        #expect(policy.usesAwdlRealtimePolicy)
        #expect(policy.targetPlayoutDelayFrames >= 1)
    }

    @Test("Balanced empty ticks do not grow playout delay")
    func balancedEmptyTicksDoNotGrowPlayoutDelay() throws {
        let streamID: StreamID = 415
        MirageRenderStreamStore.shared.clear(for: streamID)
        defer { MirageRenderStreamStore.shared.clear(for: streamID) }
        MirageRenderStreamStore.shared.setCadenceTarget(
            for: streamID,
            target: MirageMedia.MirageStreamCadenceTarget(
                sourceFPS: 60,
                displayFPS: 60,
                latencyMode: .balanced
            )
        )

        _ = MirageRenderStreamStore.shared.enqueue(
            pixelBuffer: makePixelBuffer(),
            contentRect: .zero,
            decodeTime: CFAbsoluteTimeGetCurrent(),
            presentationTime: .zero,
            for: streamID
        )
        Thread.sleep(forTimeInterval: 0.040)
        let first = try #require(MirageRenderStreamStore.shared.frameForPresentation(for: streamID, after: .zero))
        MirageRenderStreamStore.shared.markSubmitted(cursor: first.cursor, for: streamID)

        MirageRenderStreamStore.shared.noteDisplayTickWithoutFrame(for: streamID)
        MirageRenderStreamStore.shared.noteFrameArrivedAfterNoFrameTick(for: streamID, delayMs: 12)

        _ = MirageRenderStreamStore.shared.enqueue(
            pixelBuffer: makePixelBuffer(),
            contentRect: .zero,
            decodeTime: CFAbsoluteTimeGetCurrent(),
            presentationTime: CMTime(value: 1, timescale: 60),
            for: streamID
        )

        let pendingDelayMs = MirageRenderStreamStore.shared.peekPendingFrame(for: streamID)?.targetPlayoutDelayMs
        #expect(abs((pendingDelayMs ?? 0) - (1000.0 / 60.0 * 2.0)) < 0.001)
        let telemetry = MirageRenderStreamStore.shared.renderTelemetrySnapshot(for: streamID)
        #expect(abs(telemetry.smoothestTargetDelayMs - (1000.0 / 60.0 * 2.0)) < 0.001)
    }

    @Test("Smoothest hard resets only beyond the path debt limit")
    func smoothestHardResetsOnlyBeyondPathDebtLimit() {
        let policy = MiragePresentationLatencyPolicy(
            latencyMode: .smoothest,
            sourceFPS: 60,
            displayFPS: 60
        )
        let now = CFAbsoluteTimeGetCurrent()
        var softBuffer = MirageVideoPlayoutBuffer()
        var softFrames = makeRenderFrames(count: 10, decodeTime: now - 0.200).map {
            $0.withPlayoutMetadata(
                transportPathKind: .unknown,
                targetPlayoutTime: now - 0.100,
                targetPlayoutDelayMs: 250
            )
        }
        let softSelection = softBuffer.selectFrame(
            frames: &softFrames,
            after: .zero,
            policy: policy,
            now: now
        )
        #expect(softSelection.frame?.sequence == 1)
        #expect(softSelection.trimResult.smoothestFifoResetCount == 0)

        var hardBuffer = MirageVideoPlayoutBuffer()
        var hardFrames = makeRenderFrames(count: 10, decodeTime: now - 0.200).map {
            $0.withPlayoutMetadata(
                transportPathKind: .unknown,
                targetPlayoutTime: now - 0.130,
                targetPlayoutDelayMs: 250
            )
        }
        let hardSelection = hardBuffer.selectFrame(
            frames: &hardFrames,
            after: .zero,
            policy: policy,
            now: now
        )
        #expect(hardSelection.frame?.sequence == 10)
        #expect(hardSelection.trimResult.smoothestFifoResetCount == 1)
        #expect(hardFrames.count == 1)
    }

    @Test("Smoothest presentation recovery resets adapted playout delay")
    func smoothestPresentationRecoveryResetsAdaptedPlayoutDelay() throws {
        let policy = MiragePresentationLatencyPolicy(
            latencyMode: .smoothest,
            sourceFPS: 60,
            displayFPS: 60,
            transportPathKind: .wifi
        )
        let now = CFAbsoluteTimeGetCurrent()
        var buffer = MirageVideoPlayoutBuffer()
        var frames: [MirageRenderFrame] = []

        _ = buffer.enqueue(
            makeRenderFrames(count: 1, decodeTime: now)[0],
            into: &frames,
            policy: policy,
            now: now
        )
        let firstSelection = buffer.selectFrame(
            frames: &frames,
            after: .zero,
            policy: policy,
            now: now + 0.120
        )
        _ = try #require(firstSelection.frame)

        for index in 1 ... 10 {
            buffer.recordDisplayTickWithoutFrame(
                policy: policy,
                now: now + 0.120 + Double(index) * 0.060
            )
        }
        frames.removeAll()
        _ = buffer.enqueue(
            makeRenderFrames(count: 1, decodeTime: now + 0.800)[0],
            into: &frames,
            policy: policy,
            now: now + 0.800
        )
        let increasedDelay = try #require(frames.first?.targetPlayoutDelayMs)
        #expect(increasedDelay > policy.baseTargetPlayoutDelayMs)

        buffer.resetPresentationEpoch(
            policy: policy,
            now: now + 0.820,
            resetAdaptedDelay: true
        )
        frames.removeAll()
        _ = buffer.enqueue(
            makeRenderFrames(count: 1, decodeTime: now + 0.840)[0],
            into: &frames,
            policy: policy,
            now: now + 0.840
        )
        let recoveredDelay = try #require(frames.first?.targetPlayoutDelayMs)
        #expect(abs(recoveredDelay - policy.baseTargetPlayoutDelayMs) < 0.001)
    }

    @Test("Smoothest queue expands with adapted delay but remains bounded")
    func smoothestQueueExpandsWithAdaptedDelayButRemainsBounded() throws {
        let policy = MiragePresentationLatencyPolicy(
            latencyMode: .smoothest,
            sourceFPS: 60,
            displayFPS: 60,
            transportPathKind: .wifi
        )
        let baselineDepth = min(
            policy.maximumQueueDepth,
            max(1, Int(((policy.baseTargetPlayoutDelayMs + 150) / policy.displayFrameIntervalMs).rounded(.up)) + 1)
        )
        #expect(policy.maximumQueueDepth > baselineDepth)

        let now = CFAbsoluteTimeGetCurrent()
        var buffer = MirageVideoPlayoutBuffer()
        var frames: [MirageRenderFrame] = []

        _ = buffer.enqueue(
            makeRenderFrames(count: 1, decodeTime: now)[0],
            into: &frames,
            policy: policy,
            now: now
        )
        let firstSelection = buffer.selectFrame(
            frames: &frames,
            after: .zero,
            policy: policy,
            now: now + 0.120
        )
        _ = try #require(firstSelection.frame)

        for index in 1 ... 10 {
            buffer.recordDisplayTickWithoutFrame(
                policy: policy,
                now: now + 0.120 + Double(index) * 0.060
            )
        }
        #expect(buffer.smoothestDisplayDebtCapMs(policy: policy) > policy.smoothestDisplayDebtCapMs)

        frames.removeAll()
        let enqueueStart = now + 1
        var trimResult = MirageVideoPlayoutBuffer.TrimResult.empty
        for index in 0 ..< policy.maximumQueueDepth + 8 {
            let enqueueTime = enqueueStart + Double(index) * 0.001
            trimResult.absorb(buffer.enqueue(
                MirageRenderFrame(
                    pixelBuffer: makePixelBuffer(),
                    contentRect: .zero,
                    sequence: UInt64(index + 1),
                    decodeTime: enqueueTime,
                    presentationTime: CMTime(value: CMTimeValue(index), timescale: 60),
                    remotePresentationTime: .invalid
                ),
                into: &frames,
                policy: policy,
                now: enqueueTime
            ))
        }

        #expect(frames.count == policy.maximumQueueDepth)
        #expect(frames.count > baselineDepth)
        #expect(frames.first?.sequence == 9)
        #expect(trimResult.smoothestDepthDrops == 8)
    }

    @Test("Smoothest drops oldest frames once elastic age window expires")
    func smoothestDropsOldestFramesOnceElasticAgeWindowExpires() {
        let policy = MiragePresentationLatencyPolicy(
            latencyMode: .smoothest,
            sourceFPS: 60,
            displayFPS: 60,
            transportPathKind: .wifi
        )
        let now = CFAbsoluteTimeGetCurrent()
        var buffer = MirageVideoPlayoutBuffer()
        var frames = makeRenderFrames(count: 5, decodeTime: now - 0.700).map {
            $0.withPlayoutMetadata(
                transportPathKind: .wifi,
                targetPlayoutTime: now + 0.050,
                targetPlayoutDelayMs: policy.maximumTargetPlayoutDelayMs
            )
        }

        let selection = buffer.selectFrame(
            frames: &frames,
            after: .zero,
            policy: policy,
            now: now
        )

        #expect(selection.frame == nil)
        #expect(frames.count == 1)
        #expect(frames.first?.sequence == 5)
        #expect(selection.trimResult.smoothestAgeDrops == 4)
        #expect(selection.trimResult.smoothestFifoResetCount == 1)
    }

    @Test("AWDL preserves ordered playout instead of display debt FIFO reset")
    func awdlPreservesOrderedPlayoutInsteadOfDisplayDebtFifoReset() {
        let policy = MiragePresentationLatencyPolicy(
            latencyMode: .lowestLatency,
            sourceFPS: 60,
            displayFPS: 60,
            transportPathKind: .awdl,
            mediaPathProfile: .awdlRadio,
            awdlReceiverPlayoutDelayTargetMs: MirageAwdlMediaController.maximumPlayoutDelayMs
        )
        let now = CFAbsoluteTimeGetCurrent()
        var buffer = MirageVideoPlayoutBuffer()
        var frames = makeRenderFrames(count: 4, decodeTime: now - 0.180).map {
            $0.withPlayoutMetadata(
                transportPathKind: .awdl,
                targetPlayoutTime: now - 0.110,
                targetPlayoutDelayMs: MirageAwdlMediaController.maximumPlayoutDelayMs
            )
        }

        let selection = buffer.selectFrame(
            frames: &frames,
            after: .zero,
            policy: policy,
            now: now
        )

        #expect(selection.frame?.sequence == 1)
        #expect(selection.trimResult.smoothestDisplayDebtDrops == 0)
        #expect(selection.trimResult.smoothestFifoResetCount == 0)
        #expect(frames.count == 4)
    }

    @Test("AWDL drops frames after bounded realtime display debt")
    func awdlDropsFramesAfterBoundedRealtimeDisplayDebt() {
        let policy = MiragePresentationLatencyPolicy(
            latencyMode: .lowestLatency,
            sourceFPS: 60,
            displayFPS: 60,
            transportPathKind: .awdl,
            mediaPathProfile: .awdlRadio,
            awdlReceiverPlayoutDelayTargetMs: MirageAwdlMediaController.maximumPlayoutDelayMs
        )
        let now = CFAbsoluteTimeGetCurrent()
        var buffer = MirageVideoPlayoutBuffer()
        var frames = makeRenderFrames(count: 4, decodeTime: now - 0.150).map {
            $0.withPlayoutMetadata(
                transportPathKind: .awdl,
                targetPlayoutTime: now - 0.190,
                targetPlayoutDelayMs: MirageAwdlMediaController.maximumPlayoutDelayMs
            )
        }

        let selection = buffer.selectFrame(
            frames: &frames,
            after: .zero,
            policy: policy,
            now: now
        )

        #expect(selection.frame?.sequence == 4)
        #expect(selection.trimResult.smoothestDisplayDebtDrops == 3)
        #expect(selection.trimResult.smoothestFifoResetCount == 1)
        #expect(frames.count == 1)
    }

    @Test("Smoothest ProMotion tolerates short jitter without mass drops")
    func smoothestProMotionToleratesShortJitter() {
        let streamID: StreamID = 410
        MirageRenderStreamStore.shared.clear(for: streamID)
        defer { MirageRenderStreamStore.shared.clear(for: streamID) }
        MirageRenderStreamStore.shared.setCadenceTarget(
            for: streamID,
            target: MirageMedia.MirageStreamCadenceTarget(
                sourceFPS: 120,
                displayFPS: 120,
                latencyMode: .smoothest
            )
        )

        let now = CFAbsoluteTimeGetCurrent()
        for age in [0.035, 0.028, 0.020, 0.012] {
            _ = MirageRenderStreamStore.shared.enqueue(
                pixelBuffer: makePixelBuffer(),
                contentRect: .zero,
                decodeTime: now - age,
                presentationTime: CMTime(seconds: age, preferredTimescale: 600),
                for: streamID
            )
        }

        let frame = MirageRenderStreamStore.shared.frameForPresentation(for: streamID, after: .zero)
        #expect(frame == nil)

        let telemetry = MirageRenderStreamStore.shared.renderTelemetrySnapshot(for: streamID)
        #expect(telemetry.smoothestQueueDrops == 0)
        #expect(telemetry.pendingFrameCount == 4)
    }

    @Test("Presentation timing separates immediate and scheduled modes")
    func presentationTimingSeparatesImmediateAndScheduledModes() {
        let referenceTime: CFTimeInterval = 100
        let timescale: CMTimeScale = 1_000_000_000
        let cadenceTarget = MirageMedia.MirageStreamCadenceTarget(
            sourceFPS: 60,
            displayFPS: 60,
            latencyMode: .smoothest
        )
        #expect(cadenceTarget.playoutDelayFrames == 4)

        let lowestLatencyTiming = MirageRenderPresentationTiming(
            targetFPS: 60,
            playoutDelayFrames: 0,
            latencyMode: .lowestLatency
        )
        #expect(lowestLatencyTiming.displaysImmediately)
        #expect(CMTimeGetSeconds(lowestLatencyTiming.presentationTime(
            referenceTime: referenceTime,
            timescale: timescale
        )) == referenceTime)

        let smoothestTiming = MirageRenderPresentationTiming(
            targetFPS: 60,
            playoutDelayFrames: 0,
            latencyMode: .smoothest
        )
        #expect(!smoothestTiming.displaysImmediately)
        let smoothestPresentationSeconds = CMTimeGetSeconds(smoothestTiming.presentationTime(
            referenceTime: referenceTime,
            timescale: timescale
        ))
        #expect(abs(smoothestPresentationSeconds - (referenceTime + 0.008)) < 0.000_001)

        let balancedTiming = MirageRenderPresentationTiming(
            targetFPS: 60,
            playoutDelayFrames: 0,
            latencyMode: .balanced
        )
        #expect(balancedTiming.displaysImmediately)
        #expect(CMTimeGetSeconds(balancedTiming.presentationTime(
            referenceTime: referenceTime,
            timescale: timescale
        )) == referenceTime)
    }

    @Test("Immediate presentation timing does not accumulate frame-duration drift")
    func immediatePresentationTimingDoesNotAccumulateFrameDurationDrift() {
        let lowestLatencyTiming = MirageRenderPresentationTiming(
            targetFPS: 60,
            playoutDelayFrames: 0,
            latencyMode: .lowestLatency
        )
        let smoothestTiming = MirageRenderPresentationTiming(
            targetFPS: 60,
            playoutDelayFrames: 4,
            latencyMode: .smoothest
        )

        #expect(lowestLatencyTiming.minimumMonotonicPresentationStep == CMTime(value: 1, timescale: 1_000_000_000))
        #expect(smoothestTiming.minimumMonotonicPresentationStep == CMTime(value: 1, timescale: 60))
    }

    @Test("Explicit transport playout delay can raise smoothest to two frames")
    func explicitTransportPlayoutDelayCanRaiseSmoothestToTwoFrames() {
        let streamID: StreamID = 411
        MirageRenderStreamStore.shared.clear(for: streamID)
        defer { MirageRenderStreamStore.shared.clear(for: streamID) }

        let target = MirageMedia.MirageStreamCadenceTarget(
            sourceFPS: 60,
            displayFPS: 60,
            latencyMode: .smoothest,
            playoutDelayFrames: 2
        )
        #expect(target.playoutDelayFrames == 2)

        MirageRenderStreamStore.shared.setCadenceTarget(for: streamID, target: target)

        let telemetry = MirageRenderStreamStore.shared.renderTelemetrySnapshot(for: streamID)
        #expect(telemetry.playoutDelayFrames == 2)
    }

    @Test("Lowest latency display tick takes the newest decoded frame")
    func lowestLatencyDisplayTickTakesNewestDecodedFrame() {
        let streamID: StreamID = 402
        MirageRenderStreamStore.shared.clear(for: streamID)
        defer { MirageRenderStreamStore.shared.clear(for: streamID) }
        MirageRenderStreamStore.shared.setLatencyMode(for: streamID, latencyMode: .lowestLatency)

        for index in 0 ..< 3 {
            _ = MirageRenderStreamStore.shared.enqueue(
                pixelBuffer: makePixelBuffer(),
                contentRect: .zero,
                decodeTime: Double(index),
                presentationTime: CMTime(seconds: Double(index), preferredTimescale: 600),
                for: streamID
            )
        }

        let frame = MirageRenderStreamStore.shared.takePendingFrame(for: streamID)
        #expect(frame?.sequence == 3)
        #expect(MirageRenderStreamStore.shared.pendingFrameCount(for: streamID) == 0)

        let telemetry = MirageRenderStreamStore.shared.renderTelemetrySnapshot(for: streamID)
        #expect(telemetry.pendingFrameCount == 0)
        #expect(telemetry.overwrittenPendingFrames == 2)
        #expect(telemetry.smoothestQueueDrops == 0)
        #expect(telemetry.lateFrameDrops == 0)
        #expect(telemetry.coalescedBeforeSubmitCount == 2)
    }

    @Test("Repeated submission marks do not create unique forward progress")
    func repeatedSubmissionMarksDoNotRepeatUniqueProgress() {
        let streamID: StreamID = 403
        MirageRenderStreamStore.shared.clear(for: streamID)
        defer { MirageRenderStreamStore.shared.clear(for: streamID) }

        MirageRenderStreamStore.shared.markSubmitted(
            sequence: 1,
            for: streamID
        )
        MirageRenderStreamStore.shared.markSubmitted(
            sequence: 1,
            for: streamID
        )

        let telemetry = MirageRenderStreamStore.shared.renderTelemetrySnapshot(for: streamID)
        #expect(telemetry.submittedFPS >= 2)
        #expect(telemetry.uniqueSubmittedFPS >= 1)
        #expect(telemetry.uniqueSubmittedFPS < telemetry.submittedFPS)
    }

    @Test("Taking the only pending frame does not repeat on underflow")
    func underflowDoesNotRepeatPendingFrame() {
        let streamID: StreamID = 404
        MirageRenderStreamStore.shared.clear(for: streamID)
        defer { MirageRenderStreamStore.shared.clear(for: streamID) }

        _ = MirageRenderStreamStore.shared.enqueue(
            pixelBuffer: makePixelBuffer(),
            contentRect: .zero,
            decodeTime: 1,
            presentationTime: .zero,
            for: streamID
        )

        let first = MirageRenderStreamStore.shared.takePendingFrame(for: streamID)
        let second = MirageRenderStreamStore.shared.takePendingFrame(for: streamID)

        #expect(first?.sequence == 1)
        #expect(second == nil)
    }

    @Test("Display tick telemetry records missed vsync and repeated frames")
    func displayTickTelemetryRecordsMissedVSyncAndRepeatedFrames() {
        let streamID: StreamID = 405
        MirageRenderStreamStore.shared.clear(for: streamID)
        defer { MirageRenderStreamStore.shared.clear(for: streamID) }

        MirageRenderStreamStore.shared.setCadenceTarget(
            for: streamID,
            target: MirageMedia.MirageStreamCadenceTarget(sourceFPS: 60)
        )
        MirageRenderStreamStore.shared.markSubmitted(
            sequence: 1,
            for: streamID
        )
        MirageRenderStreamStore.shared.noteDisplayTick(for: streamID)
        Thread.sleep(forTimeInterval: 0.05)
        MirageRenderStreamStore.shared.noteDisplayTick(for: streamID)
        MirageRenderStreamStore.shared.noteRepeatedDisplayTick(for: streamID)

        let telemetry = MirageRenderStreamStore.shared.renderTelemetrySnapshot(for: streamID)
        #expect(telemetry.displayTickFPS >= 2)
        #expect(telemetry.missedVSyncCount >= 1)
        #expect(telemetry.repeatedFrameCount == 1)
        #expect(telemetry.displayTickIntervalP99Ms >= 40)
    }

    private func makePixelBuffer() -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            8,
            8,
            kCVPixelFormatType_32BGRA,
            nil,
            &buffer
        )
        #expect(status == kCVReturnSuccess)
        guard let buffer else {
            Issue.record("Failed to allocate CVPixelBuffer")
            fatalError("Unable to allocate CVPixelBuffer for test")
        }
        return buffer
    }

    private func makeRenderFrames(count: Int, decodeTime: CFAbsoluteTime) -> [MirageRenderFrame] {
        (0 ..< count).map { index in
            MirageRenderFrame(
                pixelBuffer: makePixelBuffer(),
                contentRect: .zero,
                sequence: UInt64(index + 1),
                decodeTime: decodeTime,
                presentationTime: CMTime(value: CMTimeValue(index), timescale: 60),
                remotePresentationTime: .invalid
            )
        }
    }
}
#endif
