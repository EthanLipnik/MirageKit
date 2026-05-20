//
//  StreamController+FrameProcessing.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/10/26.
//

import CoreGraphics
import CoreMedia
import Foundation
import MirageKit

extension StreamController {
    // MARK: - Frame Processing

    /// Starts the ordered compressed-frame queue and wires the reassembler into the decoder task.
    func startFrameProcessingPipeline() async {
        framePipelineGeneration &+= 1
        let activePipelineGeneration = framePipelineGeneration
        finishFrameQueue()
        queueDropsSinceLastLog = 0
        lastQueueDropLogTime = 0
        decodeRecoveryEscalationTimestamps.removeAll(keepingCapacity: false)
        lastBackgroundDecodeErrorSignature = nil
        lastBackgroundDecodeErrorLogTime = 0
        consecutiveDecodeErrors = 0
        lastDecodeErrorSignature = nil
        lastDecodeErrorLogTime = 0
        lastPresentedSequenceObserved = 0
        lastPresentedProgressTime = 0
        lastFreezeRecoveryTime = 0
        consecutiveFreezeRecoveries = 0
        metricsTracker.reset()
        decodeSubmissionStressStreak = 0
        decodeSubmissionHealthyStreak = 0
        currentDecodeSubmissionLimit = decodeSubmissionBaselineLimit
        await decoder.setDecodeSubmissionLimit(
            limit: decodeSubmissionBaselineLimit,
            reason: "stream pipeline start"
        )
        nextExpectedEnqueueOrder = 0
        enqueueOrderAllocator.reset()
        pendingOrderedFrames.removeAll(keepingCapacity: false)

        // Start the frame processing task - single task processes all frames sequentially
        let capturedDecoder = decoder
        let decodeBudgetController = GlobalDecodeBudgetController.shared
        frameProcessingTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                guard let frame = await dequeueFrame() else { break }
                defer { frame.releaseBuffer() }
                guard let lease = await decodeBudgetController.acquire(streamID: streamID) else { break }
                do {
                    try await capturedDecoder.decodeFrame(
                        frame.data,
                        presentationTime: frame.presentationTime,
                        isKeyframe: frame.isKeyframe,
                        contentRect: frame.contentRect
                    )
                    await recordDecodeSuccessIfNeeded()
                } catch {
                    await recordDecodeFailure(error)
                }
                await decodeBudgetController.release(lease)
            }
        }

        // Set up reassembler callback - enqueue frames for ordered processing
        let metricsTrackerSnapshot = metricsTracker
        let enqueueOrderAllocatorSnapshot = enqueueOrderAllocator
        let reassemblerHandler: @Sendable (
            StreamID,
            Data,
            Bool,
            UInt32,
            UInt64,
            UInt16,
            UInt16,
            CGRect,
            @escaping @Sendable () -> Void
        )
            -> Void = { [weak self] _, frameData, isKeyframe, frameNumber, timestamp, _, _, contentRect, releaseBuffer in
                metricsTrackerSnapshot.recordReceivedFrame()
                let enqueueOrder = enqueueOrderAllocatorSnapshot.allocate()

                Task {
                    guard let self else {
                        releaseBuffer()
                        return
                    }
                    await self.enqueueReassembledFrame(
                        data: frameData,
                        frameNumber: frameNumber,
                        remoteTimestamp: timestamp,
                        isKeyframe: isKeyframe,
                        contentRect: contentRect,
                        releaseBuffer: releaseBuffer,
                        enqueueOrder: enqueueOrder,
                        pipelineGeneration: activePipelineGeneration
                    )
                }
            }
        reassembler.setFrameHandler(reassemblerHandler)
        reassembler.setFrameLossHandler { [weak self] _, reason in
            guard let self else { return }
            Task {
                await self.handleFrameLossSignal(reason: reason)
            }
        }
    }

    /// Resets frame assembly and cadence correction after the decoder observes a dimension change.
    func resetReassemblerForDimensionChange(streamID capturedStreamID: StreamID) {
        reassembler.reset()
        streamCadenceClock.reset(targetFPS: streamCadenceTarget.sourceFPS)
        MirageLogger.client("Reassembler reset due to dimension change for stream \(capturedStreamID)")
    }

    /// Stops frame processing and releases queued compressed frame buffers.
    func stopFrameProcessingPipeline() {
        framePipelineGeneration &+= 1
        finishFrameQueue()
        frameProcessingTask?.cancel()
        frameProcessingTask = nil
    }

    private func recordDecodeSuccessIfNeeded() {
        guard isRunning, !isStopping else {
            lastBackgroundDecodeErrorSignature = nil
            lastBackgroundDecodeErrorLogTime = 0
            consecutiveDecodeErrors = 0
            lastDecodeErrorSignature = nil
            lastDecodeErrorLogTime = 0
            return
        }
        guard consecutiveDecodeErrors > 0 ||
            lastBackgroundDecodeErrorSignature != nil ||
            lastBackgroundDecodeErrorLogTime > 0 else { return }
        MirageLogger.debug(
            .client,
            "Decode pipeline recovered after \(consecutiveDecodeErrors) consecutive error(s)"
        )
        lastBackgroundDecodeErrorSignature = nil
        lastBackgroundDecodeErrorLogTime = 0
        consecutiveDecodeErrors = 0
        lastDecodeErrorSignature = nil
        lastDecodeErrorLogTime = 0
    }

    private func enqueueReassembledFrame(
        data: Data,
        frameNumber: UInt32,
        remoteTimestamp: UInt64,
        isKeyframe: Bool,
        contentRect: CGRect,
        releaseBuffer: @escaping @Sendable () -> Void,
        enqueueOrder: UInt64,
        pipelineGeneration: UInt64
    )
    async {
        guard pipelineGeneration == framePipelineGeneration else {
            releaseBuffer()
            return
        }

        let remotePresentationTime = CMTime(value: CMTimeValue(remoteTimestamp), timescale: 1_000_000_000)
        let timing = streamCadenceClock.timing(
            frameNumber: frameNumber,
            remotePresentationTime: remotePresentationTime,
            isKeyframe: isKeyframe
        )
        MirageRenderStreamStore.shared.recordFrameTimingDiagnostics(
            for: streamID,
            duplicateRemoteTimestamp: timing.duplicateRemoteTimestamp,
            correctedStreamTimestamp: timing.correctedStreamTimestamp
        )
        decodeFrameTimingCache.insert(
            streamPresentationTime: timing.streamPresentationTime,
            remotePresentationTime: remotePresentationTime
        )
        let frame = FrameData(
            data: data,
            presentationTime: timing.streamPresentationTime,
            isKeyframe: isKeyframe,
            contentRect: contentRect,
            releaseBuffer: releaseBuffer
        )
        await enqueueFrame(
            frame,
            enqueueOrder: enqueueOrder,
            pipelineGeneration: pipelineGeneration
        )
    }

    private func enqueueFrame(
        _ frame: FrameData,
        enqueueOrder: UInt64,
        pipelineGeneration: UInt64
    )
    async {
        guard pipelineGeneration == framePipelineGeneration else {
            frame.releaseBuffer()
            return
        }

        pendingOrderedFrames[enqueueOrder] = frame
        while let nextFrame = pendingOrderedFrames.removeValue(forKey: nextExpectedEnqueueOrder) {
            nextExpectedEnqueueOrder &+= 1
            await enqueueFrameInOrder(nextFrame)
        }
    }

    private func enqueueFrameInOrder(_ frame: FrameData) async {
        if let continuation = dequeueContinuation {
            dequeueContinuation = nil
            continuation.resume(returning: frame)
            return
        }

        if presentationTier == .passiveSnapshot {
            if !queuedFrames.isEmpty {
                discardQueuedFramesForRecovery()
            }
            queuedFrames.append(frame)
            return
        }

        if queuedFrames.count >= Self.maxQueuedFrames {
            let queueDepth = queuedFrames.count
            if frame.isKeyframe {
                discardQueuedFramesForRecovery()
                queuedFrames.append(frame)
                maybeLogDecodeBackpressure(queueDepth: queueDepth)
                return
            }

            frame.releaseBuffer()
            recordQueueDrop()
            maybeLogDecodeBackpressure(queueDepth: queueDepth)
            logQueueDropIfNeeded()
            return
        }

        queuedFrames.append(frame)
    }

    private func dequeueFrame() async -> FrameData? {
        let frame: FrameData? = if !queuedFrames.isEmpty {
            queuedFrames.popFirst()
        } else {
            await withCheckedContinuation { continuation in
                dequeueContinuation = continuation
            }
        }
        guard frame != nil else { return nil }
        await maybeApplyAdaptiveJitterHold()
        return frame
    }

    private func maybeApplyAdaptiveJitterHold() async {
        guard awdlExperimentEnabled, awdlTransportActive else { return }
        let holdMs = max(0, min(Self.adaptiveJitterHoldMaxMs, adaptiveJitterHoldMs))
        guard holdMs > 0 else { return }
        do {
            try await Task.sleep(for: .milliseconds(Int64(holdMs)))
        } catch {
            return
        }
    }

    private func finishFrameQueue() {
        if let continuation = dequeueContinuation {
            dequeueContinuation = nil
            continuation.resume(returning: nil)
        }
        decodeFrameTimingCache.clear()
        discardQueuedFramesForRecovery()
    }

    /// Releases and counts all compressed frames that have not reached the decoder yet.
    func clearQueuedFramesForRecovery() -> Int {
        let frames = drainQueuedAndPendingFrames()
        release(frames)
        return frames.count
    }

    /// Releases pending compressed frames without reporting a trim count.
    func discardQueuedFramesForRecovery() {
        release(drainQueuedAndPendingFrames())
    }

    private func drainQueuedAndPendingFrames() -> [FrameData] {
        let queued = queuedFrames.drain()
        let pending = Array(pendingOrderedFrames.values)
        pendingOrderedFrames.removeAll(keepingCapacity: false)
        nextExpectedEnqueueOrder = 0
        enqueueOrderAllocator.reset()
        return queued + pending
    }

    private func release(_ frames: [FrameData]) {
        for frame in frames {
            frame.releaseBuffer()
        }
    }

    /// Returns whether shared clipboard data should wait until decoder recovery is no longer active.
    var shouldDeferSharedClipboardApply: Bool {
        clientRecoveryStatus != .idle || reassembler.isAwaitingKeyframe
    }

    /// Trims queued decode state under memory pressure and optionally resets the decoder session.
    func handleMemoryPressure(resetDecoder: Bool = false) async -> Bool {
        let queuedFramesTrimmed = clearQueuedFramesForRecovery()
        let reassemblerTrim = reassembler.trimForMemoryPressure()
        let renderFramesTrimmed = MirageRenderStreamStore.shared.clearPendingFrames(for: streamID)
        if resetDecoder {
            await decoder.resetForNewSession()
        } else {
            await decoder.flushMemoryPool()
        }

        let didTrim = queuedFramesTrimmed > 0 ||
            reassemblerTrim.evictedFrames > 0 ||
            reassemblerTrim.purgedRetainedBytes > 0 ||
            renderFramesTrimmed > 0 ||
            resetDecoder
        guard didTrim else { return false }

        MirageLogger.client(
            "Memory pressure trimmed stream \(streamID): queuedFrames=\(queuedFramesTrimmed), " +
                "reassemblerFrames=\(reassemblerTrim.evictedFrames), renderFrames=\(renderFramesTrimmed), " +
                "reassemblerBytes=\(reassemblerTrim.releasedPendingBytes), " +
                "purgedRetainedBytes=\(reassemblerTrim.purgedRetainedBytes), resetDecoder=\(resetDecoder)"
        )

        if isRunning, !isStopping {
            await requestKeyframeRecoveryIfPossible(reason: .manualRecovery)
        }

        return true
    }
}
