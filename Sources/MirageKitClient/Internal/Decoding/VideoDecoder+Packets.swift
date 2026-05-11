//
//  VideoDecoder+Packets.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  HEVC decoder extensions.
//

import CoreGraphics
import Foundation
import MirageKit

extension FrameReassembler {
    struct PendingKeyframeProgress: Sendable, Equatable {
        let frameNumber: UInt32
        let receivedCount: Int
        let totalCount: Int
        let lastProgressTime: CFAbsoluteTime
    }

    func setFrameHandler(_ handler: @escaping @Sendable (
        StreamID,
        Data,
        Bool,
        UInt32,
        UInt64,
        UInt16,
        UInt16,
        CGRect,
        FrameTimeline,
        @escaping @Sendable () -> Void
    )
        -> Void) {
        lock.lock()
        onFrameComplete = handler
        lock.unlock()
    }

    func setFrameHandler(_ handler: @escaping @Sendable (
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
        -> Void) {
        setFrameHandler { streamID, data, isKeyframe, frameNumber, timestamp, epoch, dimensionToken, contentRect, _, release in
            handler(streamID, data, isKeyframe, frameNumber, timestamp, epoch, dimensionToken, contentRect, release)
        }
    }

    func setFrameHandler(_ handler: @escaping @Sendable (
        StreamID,
        Data,
        Bool,
        UInt64,
        CGRect,
        @escaping @Sendable () -> Void
    )
        -> Void) {
        setFrameHandler { streamID, data, isKeyframe, _, timestamp, _, _, contentRect, _, release in
            handler(streamID, data, isKeyframe, timestamp, contentRect, release)
        }
    }

    func setFrameLossHandler(_ handler: @escaping @Sendable (StreamID, FrameLossReason) -> Void) {
        lock.lock()
        onFrameLoss = handler
        lock.unlock()
    }

    func updateExpectedDimensionToken(_ token: UInt16) {
        lock.lock()
        expectedDimensionToken = token
        dimensionTokenValidationEnabled = true
        lock.unlock()
        MirageLogger.log(.frameAssembly, "Expected dimension token updated to \(token) for stream \(streamID)")
    }

    func setTargetFrameRate(_ frameRate: Int) {
        let sanitizedFrameRate = max(1, min(240, frameRate))
        lock.lock()
        let previousFrameRate = targetFrameRate
        targetFrameRate = sanitizedFrameRate
        lock.unlock()

        guard previousFrameRate != sanitizedFrameRate else { return }
        MirageLogger.log(.frameAssembly, "Reassembler target frame rate updated to \(sanitizedFrameRate)fps for stream \(streamID)")
    }

    func processPacket(_ data: Data, header: FrameHeader) {
        var completedFrames: [CompletedFrame] = []
        var completionHandler: (@Sendable (
            StreamID,
            Data,
            Bool,
            UInt32,
            UInt64,
            UInt16,
            UInt16,
            CGRect,
            FrameTimeline,
            @escaping @Sendable () -> Void
        )
            -> Void)?
        var shouldSignalFrameLoss = false
        var frameLossReason: FrameLossReason?

        let frameNumber = header.frameNumber
        let isKeyframePacket = header.flags.contains(.keyframe)
        let packetReceivedAt = Date()
        let packetReceiveTime = packetReceivedAt.timeIntervalSinceReferenceDate
        lock.lock()
        lastPacketReceivedTime = packetReceivedAt.timeIntervalSinceReferenceDate
        totalPacketsReceived += 1

        let epochIsNewer = isEpochNewer(header.epoch, than: currentEpoch)
        let epochIsCurrentOrNewer = header.epoch == currentEpoch || epochIsNewer

        if header.epoch != currentEpoch {
            if isKeyframePacket, epochIsNewer { resetForEpoch(header.epoch, reason: "epoch mismatch") } else {
                packetsDiscardedEpoch += 1
                beginAwaitingKeyframe()
                lock.unlock()
                return
            }
        }

        if header.flags.contains(.discontinuity) {
            if isKeyframePacket, epochIsCurrentOrNewer { resetForEpoch(header.epoch, reason: "discontinuity") } else {
                packetsDiscardedEpoch += 1
                beginAwaitingKeyframe()
                lock.unlock()
                return
            }
        }

        if isKeyframePacket, isStaleKeyframeLocked(frameNumber) {
            if hasDeliveredKeyframeAnchor, frameNumber == lastDeliveredKeyframe {
                packetsDiscardedDeliveredKeyframe += 1
            } else {
                packetsDiscardedOld += 1
            }
            lock.unlock()
            return
        }

        // Validate dimension tokens to reject packets from old resize generations.
        // The expected token is controlled by resize/window-selection state; packets
        // must not advance it because stale keyframes can arrive after a new geometry.
        if dimensionTokenValidationEnabled {
            if header.dimensionToken != expectedDimensionToken {
                packetsDiscardedToken += 1
                if isKeyframePacket {
                    MirageLogger.log(
                        .frameAssembly,
                        "Discarding keyframe with dimension token \(header.dimensionToken); expected \(expectedDimensionToken)"
                    )
                    beginAwaitingKeyframe()
                }
                lock.unlock()
                return
            }
        }

        if awaitingKeyframe && !isKeyframePacket {
            packetsDiscardedAwaitingKeyframe += 1
            lock.unlock()
            return
        }

        // Validate CRC32 checksum unless encrypted packets explicitly opt into AEAD-only integrity.
        if mirageShouldValidatePayloadChecksum(
            isEncrypted: header.flags.contains(.encryptedPayload),
            checksum: header.checksum
        ) {
            let calculatedCRC = CRC32.calculate(data)
            if calculatedCRC != header.checksum {
                packetsDiscardedCRC += 1
                MirageLogger.log(
                    .frameAssembly,
                    "CRC mismatch for frame \(frameNumber) fragment \(header.fragmentIndex) - discarding (expected \(header.checksum), got \(calculatedCRC))"
                )
                beginAwaitingKeyframe()
                let lossHandler = onFrameLoss
                lock.unlock()
                lossHandler?(streamID, .payloadIntegrity)
                return
            }
        }

        // Skip old P-frames, but NEVER skip keyframe packets.
        // Keyframes are large (400+ packets) and take longer to transmit than small P-frames.
        // P-frames sent after a keyframe may complete before the keyframe finishes.
        // If we skip "old" keyframe packets, recovery becomes impossible.
        let isOldFrame = frameNumber < lastCompletedFrame && lastCompletedFrame - frameNumber < 1000
        if isOldFrame && !isKeyframePacket {
            packetsDiscardedOld += 1
            lock.unlock()
            return
        }

        let frameByteCount = resolvedFrameByteCount(header: header, maxPayloadSize: maxPayloadSize)
        let dataFragmentCount = resolvedDataFragmentCount(
            header: header,
            frameByteCount: frameByteCount,
            maxPayloadSize: maxPayloadSize
        )
        let usesHeaderByteCount = frameByteCount > 0
        let frame: PendingFrame
        if let existingFrame = pendingFrames[frameNumber] { frame = existingFrame } else {
            let capacity = max(1, dataFragmentCount) * maxPayloadSize
            let buffer = bufferPool.acquire(capacity: capacity)
            let timeline = FrameTimeline(
                streamID: streamID,
                frameNumber: frameNumber,
                dependencyEpoch: DependencyEpoch(header.epoch),
                isKeyframe: isKeyframePacket,
                encodedByteCount: frameByteCount,
                fragmentCount: dataFragmentCount,
                firstPacketReceiveTime: packetReceiveTime,
                lastPacketReceiveTime: packetReceiveTime
            )
            frame = PendingFrame(
                buffer: buffer,
                receivedMap: Array(repeating: false, count: dataFragmentCount),
                receivedCount: 0,
                totalFragments: header.fragmentCount,
                dataFragmentCount: dataFragmentCount,
                fecBlockSize: Int(header.fecBlockSize),
                isKeyframe: isKeyframePacket,
                timestamp: header.timestamp,
                epoch: header.epoch,
                dimensionToken: header.dimensionToken,
                receivedAt: packetReceivedAt,
                lastProgressAt: packetReceivedAt,
                contentRect: header.contentRect,
                expectedTotalBytes: usesHeaderByteCount ? frameByteCount : capacity,
                timeline: timeline
            )
            pendingFrames[frameNumber] = frame
        }

        // Update keyframe flag if this packet has it (in case fragments arrive out of order)
        if isKeyframePacket && !frame.isKeyframe { frame.isKeyframe = true }

        // Keep incomplete keyframes long enough for recovery, but bound retained memory.
        // Budget enforcement below preserves the newest keyframe candidate while trimming
        // older keyframes and non-keyframes under pressure.

        // Store fragment
        let fragmentIndex = Int(header.fragmentIndex)
        let isParityFragment = header.flags.contains(.fecParity) || fragmentIndex >= frame.dataFragmentCount
        if isParityFragment {
            let parityIndex = max(0, fragmentIndex - frame.dataFragmentCount)
            if frame.parityFragments[parityIndex] == nil {
                frame.parityFragments[parityIndex] = data
                frame.receivedParityCount += 1
                frame.lastProgressAt = packetReceivedAt
                tryRecoverMissingFragment(
                    frame: frame,
                    parityIndex: parityIndex,
                    frameByteCount: frameByteCount
                )
            }
        } else if fragmentIndex >= 0, fragmentIndex < frame.receivedMap.count {
            if !frame.receivedMap[fragmentIndex] {
                let offset = fragmentIndex * maxPayloadSize
                frame.buffer.write(data, at: offset)
                frame.receivedMap[fragmentIndex] = true
                frame.receivedCount += 1
                frame.lastProgressAt = packetReceivedAt
                frame.timeline = frame.timeline.markingPacketReceived(
                    at: packetReceiveTime,
                    receivedFragmentCount: frame.receivedCount
                )
                if !usesHeaderByteCount, fragmentIndex == frame.receivedMap.count - 1 {
                    let end = offset + data.count
                    frame.expectedTotalBytes = min(end, frame.buffer.capacity)
                }
                if let parityIndex = parityIndexForDataFragment(
                    fragmentIndex: fragmentIndex,
                    frame: frame
                ) {
                    tryRecoverMissingFragment(
                        frame: frame,
                        parityIndex: parityIndex,
                        frameByteCount: frameByteCount
                    )
                }
            }
        }

        // Log keyframe assembly progress for diagnostics
        if frame.isKeyframe {
            let receivedCount = frame.receivedCount
            let totalCount = frame.dataFragmentCount
            // Log at key milestones: first packet, 25%, 50%, 75%, and when nearly complete
            if receivedCount == 1 || receivedCount == totalCount / 4 || receivedCount == totalCount / 2 ||
                receivedCount == (totalCount * 3) / 4 || receivedCount == totalCount - 1 {
                MirageLogger.log(
                    .frameAssembly,
                    "Keyframe \(frameNumber): \(receivedCount)/\(totalCount) fragments received"
                )
            }
        }

        // Check if frame is complete.
        if !frame.isComplete, frame.receivedCount == frame.dataFragmentCount {
            frame.isComplete = true
            let completionResult = completeFrameLocked(frameNumber: frameNumber, frame: frame)
            if let completedFrame = completionResult.frame {
                completedFrames.append(completedFrame)
                let drainResult = drainDeliverableFramesLocked()
                if !drainResult.frames.isEmpty {
                    completedFrames.append(contentsOf: drainResult.frames)
                }
                if let drainLossReason = drainResult.frameLossReason {
                    shouldSignalFrameLoss = true
                    frameLossReason = frameLossReason ?? drainLossReason
                }
            }
            if let completionLossReason = completionResult.frameLossReason {
                shouldSignalFrameLoss = true
                frameLossReason = frameLossReason ?? completionLossReason
            }
            completionHandler = onFrameComplete
        }

        // Clean up old pending frames
        let timeoutResult = cleanupOldFramesLocked()
        if timeoutResult.shouldEnterAwaitingKeyframe {
            enterKeyframeOnlyModeLocked()
            MirageLogger.log(
                .frameAssembly,
                "Entering keyframe wait after timeout: pFrame=\(timeoutResult.timedOutPFrames), keyframe=\(timeoutResult.timedOutKeyframes), anchor=\(hasDeliveredKeyframeAnchor)"
            )
        }
        if timeoutResult.timedOutPFrames + timeoutResult.timedOutKeyframes > 0 {
            shouldSignalFrameLoss = true
            frameLossReason = frameLossReason ?? timeoutResult.frameLossReason
        }
        if timeoutResult.missingExpectedPFrameGapTimedOut, !hasSignaledGapFrameLoss {
            shouldSignalFrameLoss = true
            hasSignaledGapFrameLoss = true
            frameLossReason = frameLossReason ?? .forwardGapTimeout
        }
        if !awaitingKeyframe,
           shouldPromotePendingKeyframeLocked(now: packetReceivedAt) {
            let expectedFrame = lastCompletedFrame &+ 1
            promotePendingKeyframeLocked()
            shouldSignalFrameLoss = true
            hasSignaledGapFrameLoss = true
            MirageLogger.log(
                .frameAssembly,
                "Promoting pending keyframe over stalled P-frame gap: expected=\(expectedFrame)"
            )
        }

        let budgetEvictions = enforceMemoryBudgetLocked()
        if budgetEvictions > 0 {
            shouldSignalFrameLoss = true
            frameLossReason = frameLossReason ?? .memoryBudget
        }
        lock.unlock()

        if shouldSignalFrameLoss {
            if let onFrameLoss {
                onFrameLoss(streamID, frameLossReason ?? .timeout)
            }
        }

        if !completedFrames.isEmpty, let completionHandler {
            for completedFrame in completedFrames {
                completionHandler(
                    streamID,
                    completedFrame.data,
                    completedFrame.isKeyframe,
                    completedFrame.frameNumber,
                    completedFrame.timestamp,
                    completedFrame.epoch,
                    completedFrame.dimensionToken,
                    completedFrame.contentRect,
                    completedFrame.timeline,
                    completedFrame.releaseBuffer
                )
            }
        }
    }

    private struct CompletedFrame {
        let data: Data
        let isKeyframe: Bool
        let frameNumber: UInt32
        let timestamp: UInt64
        let epoch: UInt16
        let dimensionToken: UInt16
        let contentRect: CGRect
        let timeline: FrameTimeline
        let releaseBuffer: @Sendable () -> Void
    }

    private struct FrameCompletionResult {
        let frame: CompletedFrame?
        let frameLossReason: FrameLossReason?
        let retainedForInOrderDelivery: Bool
    }

    private struct DrainCompletionResult {
        let frames: [CompletedFrame]
        let frameLossReason: FrameLossReason?
    }

    private struct TimeoutCleanupResult {
        let timedOutPFrames: UInt64
        let timedOutKeyframes: UInt64
        let staleKeyframes: UInt64
        let timedOutExpectedPFrame: Bool
        let missingExpectedPFrameGapTimedOut: Bool
        let shouldEnterAwaitingKeyframe: Bool

        var frameLossReason: FrameLossReason? {
            if timedOutExpectedPFrame || missingExpectedPFrameGapTimedOut {
                return .forwardGapTimeout
            }
            if timedOutPFrames + timedOutKeyframes > 0 {
                return .timeout
            }
            return nil
        }

        var shouldSignalFrameLoss: Bool {
            timedOutPFrames + timedOutKeyframes > 0 || missingExpectedPFrameGapTimedOut
        }
    }

    private func completeFrameLocked(frameNumber: UInt32, frame: PendingFrame) -> FrameCompletionResult {
        // Frame skipping logic: determine if we should deliver this frame
        let shouldDeliver: Bool
        var retainedForInOrderDelivery = false

        if frame.isKeyframe {
            // Always deliver keyframes unless a newer keyframe was already delivered.
            shouldDeliver = !hasDeliveredKeyframeAnchor || isFrameNewer(frameNumber, than: lastDeliveredKeyframe)
            if shouldDeliver {
                lastDeliveredKeyframe = frameNumber
                hasDeliveredKeyframeAnchor = true
            }
        } else {
            // For P-frames: require a delivered keyframe anchor and strict frame monotonicity.
            // If a forward gap is detected, enter keyframe wait and recover from the next keyframe.
            guard hasDeliveredKeyframeAnchor else {
                shouldDeliver = false
                pendingFrames.removeValue(forKey: frameNumber)
                frame.buffer.release()
                droppedFrameCount += 1
                return FrameCompletionResult(
                    frame: nil,
                    frameLossReason: nil,
                    retainedForInOrderDelivery: false
                )
            }
            let expectedNextFrame = lastCompletedFrame &+ 1
            let isForwardFrame = isFrameNewer(frameNumber, than: lastCompletedFrame)
            let isAfterKeyframeAnchor = isFrameNewer(frameNumber, than: lastDeliveredKeyframe)
            let hasForwardGap = isForwardFrame && isFrameNewer(frameNumber, than: expectedNextFrame)

            if hasForwardGap {
                let gapFrames = frameNumber &- expectedNextFrame
                let severeForwardGapFrameThreshold = severeForwardGapFrameThresholdLocked()
                if gapFrames >= severeForwardGapFrameThreshold {
                    shouldDeliver = false
                    enterKeyframeOnlyModeLocked()
                    hasSignaledGapFrameLoss = true
                    MirageLogger.log(
                        .frameAssembly,
                        "Severe forward gap detected: expected=\(expectedNextFrame) received=\(frameNumber) " +
                            "gapFrames=\(gapFrames), threshold=\(severeForwardGapFrameThreshold); entering keyframe-only mode"
                    )
                    return FrameCompletionResult(
                        frame: nil,
                        frameLossReason: .severeForwardGap,
                        retainedForInOrderDelivery: false
                    )
                }
                shouldDeliver = false
                retainedForInOrderDelivery = true
                MirageLogger.log(
                    .frameAssembly,
                    "gap_buffered_for_ordering expected=\(expectedNextFrame) received=\(frameNumber) gapFrames=\(gapFrames)"
                )
            } else {
                shouldDeliver = isForwardFrame && isAfterKeyframeAnchor
            }
        }

        if shouldDeliver {
            // Discard any pending frames older than this one
            discardOlderPendingFramesLocked(olderThan: frameNumber)
            purgeStaleKeyframesLocked()

            lastCompletedFrame = frameNumber
            hasSignaledGapFrameLoss = false
            pendingFrames.removeValue(forKey: frameNumber)

            framesDelivered += 1
            if frame.isKeyframe {
                MirageLogger.log(
                    .frameAssembly,
                    "Delivering keyframe \(frameNumber) (\(frame.expectedTotalBytes) bytes)"
                )
                MirageLogger.client(
                    "Keyframe assembled: frame=\(frameNumber), size=\(frame.expectedTotalBytes), stream=\(streamID)"
                )
                clearAwaitingKeyframe()
            }
            let output = frame.buffer.finalize(length: frame.expectedTotalBytes)
            let now = CFAbsoluteTimeGetCurrent()
            let queueAgeMs = max(0, now - frame.receivedAt.timeIntervalSinceReferenceDate) * 1000
            let timeline = frame.timeline.markingReassembled(
                at: now,
                byteCount: output.count,
                receivedFragmentCount: frame.receivedCount,
                queueAgeMs: queueAgeMs
            )

            if !frame.isKeyframe {
                MirageFrameIntegrityDiagnostics.shared.recordPFrame(
                    source: .reassembledPFrame,
                    streamID: streamID,
                    frameNumber: frameNumber,
                    frameBytes: output,
                    expectedBytes: frame.expectedTotalBytes
                )
            }

            let buffer = frame.buffer
            let releaseBuffer: @Sendable () -> Void = { buffer.release() }
            return FrameCompletionResult(
                frame: CompletedFrame(
                    data: output,
                    isKeyframe: frame.isKeyframe,
                    frameNumber: frameNumber,
                    timestamp: frame.timestamp,
                    epoch: frame.epoch,
                    dimensionToken: frame.dimensionToken,
                    contentRect: frame.contentRect,
                    timeline: timeline,
                    releaseBuffer: releaseBuffer
                ),
                frameLossReason: nil,
                retainedForInOrderDelivery: false
            )
        } else {
            if retainedForInOrderDelivery {
                return FrameCompletionResult(
                    frame: nil,
                    frameLossReason: nil,
                    retainedForInOrderDelivery: true
                )
            }

            // This frame arrived too late - a newer frame was already delivered
            if frame.isKeyframe {
                MirageLogger.log(
                    .frameAssembly,
                    "WARNING: Keyframe \(frameNumber) NOT delivered (lastDeliveredKeyframe=\(lastDeliveredKeyframe))"
                )
            }
            pendingFrames.removeValue(forKey: frameNumber)
            frame.buffer.release()
            droppedFrameCount += 1
            return FrameCompletionResult(
                frame: nil,
                frameLossReason: nil,
                retainedForInOrderDelivery: false
            )
        }
    }

    private func drainDeliverableFramesLocked() -> DrainCompletionResult {
        var drainedFrames: [CompletedFrame] = []
        var frameLossReason: FrameLossReason?

        while hasDeliveredKeyframeAnchor {
            let expectedFrameNumber = lastCompletedFrame &+ 1
            guard let expectedFrame = pendingFrames[expectedFrameNumber], expectedFrame.isComplete else { break }

            let completionResult = completeFrameLocked(
                frameNumber: expectedFrameNumber,
                frame: expectedFrame
            )
            if let completedFrame = completionResult.frame {
                drainedFrames.append(completedFrame)
            }
            if let completionLossReason = completionResult.frameLossReason {
                frameLossReason = completionLossReason
            }
            if completionResult.retainedForInOrderDelivery {
                break
            }
        }

        return DrainCompletionResult(
            frames: drainedFrames,
            frameLossReason: frameLossReason
        )
    }

    private func discardOlderPendingFramesLocked(olderThan frameNumber: UInt32) {
        let framesToDiscard = pendingFrames.keys.filter { pendingFrameNumber in
            // Discard P-frames older than the one we're about to deliver
            // Handle wrap-around: if difference is huge, it's probably wrap-around
            guard pendingFrameNumber < frameNumber, frameNumber - pendingFrameNumber < 1000 else { return false }
            // NEVER discard pending keyframes - they're critical for decoder recovery
            // Keyframes are large (500+ packets) and take longer to arrive than P-frames
            // If we discard an incomplete keyframe, the decoder will be stuck
            if let frame = pendingFrames[pendingFrameNumber], frame.isKeyframe { return false }
            return true
        }

        for discardFrame in framesToDiscard {
            if let frame = pendingFrames[discardFrame] {
                droppedFrameCount += 1
                frame.buffer.release()
                pendingFrames.removeValue(forKey: discardFrame)
            }
        }
    }

    private func resetForEpoch(_ epoch: UInt16, reason: String) {
        currentEpoch = epoch
        for frame in pendingFrames.values {
            frame.buffer.release()
        }
        pendingFrames.removeAll()
        lastCompletedFrame = 0
        lastDeliveredKeyframe = 0
        hasDeliveredKeyframeAnchor = false
        hasSignaledGapFrameLoss = false
        clearAwaitingKeyframe()
        beginAwaitingKeyframe()
        packetsDiscardedAwaitingKeyframe = 0
        MirageLogger.log(.frameAssembly, "Epoch \(epoch) reset (\(reason)) for stream \(streamID)")
    }

    private func isEpochNewer(_ incoming: UInt16, than current: UInt16) -> Bool {
        let diff = UInt16(incoming &- current)
        // Treat epochs as monotonically increasing with wrap-around semantics.
        // Values in the "forward" half-range are considered newer.
        return diff != 0 && diff < 0x8000
    }

    private func isFrameNewer(_ incoming: UInt32, than current: UInt32) -> Bool {
        let diff = incoming &- current
        return diff != 0 && diff < 0x8000_0000
    }

    private func cleanupOldFramesLocked() -> TimeoutCleanupResult {
        let now = Date()
        let pFrameTimeout = pFrameTimeoutLocked()

        var timedOutPFrameCount: UInt64 = 0
        var timedOutKeyframeCount: UInt64 = 0
        var staleKeyframeCount: UInt64 = 0
        var timedOutExpectedPFrame = false
        var framesToRemove: [UInt32] = []
        for (frameNumber, frame) in pendingFrames {
            if frame.isKeyframe, isStaleKeyframeLocked(frameNumber) {
                framesToRemove.append(frameNumber)
                staleKeyframeCount += 1
                continue
            }
            let timeout = if frame.isKeyframe {
                startupKeyframeTimeoutOverrideEnabled ? startupKeyframeTimeout : keyframeTimeout
            } else {
                pFrameTimeout
            }
            let progressReference = frame.isKeyframe ? frame.lastProgressAt : frame.receivedAt
            let shouldKeep = now.timeIntervalSince(progressReference) < timeout
            if !shouldKeep {
                // Log timeout with fragment completion info for debugging
                let receivedCount = frame.receivedCount
                let totalCount = frame.dataFragmentCount
                let isKeyframe = frame.isKeyframe
                MirageLogger.log(
                    .frameAssembly,
                    "Frame \(frameNumber) timed out: \(receivedCount)/\(totalCount) fragments\(isKeyframe ? " (KEYFRAME)" : "")"
                )
                if isKeyframe {
                    timedOutKeyframeCount += 1
                    MirageLogger.client(
                        "Keyframe timed out: frame=\(frameNumber), \(receivedCount)/\(totalCount) fragments, stream=\(streamID)"
                    )
                } else {
                    timedOutPFrameCount += 1
                    let expectedFrame = lastCompletedFrame &+ 1
                    if frameNumber == expectedFrame {
                        timedOutExpectedPFrame = true
                    }
                }
            }
            if !shouldKeep { framesToRemove.append(frameNumber) }
        }
        let missingExpectedPFrameGapTimedOut = hasDeliveredKeyframeAnchor &&
            timedOutExpectedPFrame == false &&
            hasTimedOutBufferedForwardGapLocked(now: now, timeout: pFrameTimeout)
        for frameNumber in framesToRemove {
            if let frame = pendingFrames.removeValue(forKey: frameNumber) { frame.buffer.release() }
        }
        droppedFrameCount += timedOutPFrameCount + timedOutKeyframeCount + staleKeyframeCount

        // HEVC P-frames can reference prior P-frames. Once a forward P-frame gap
        // times out, later P-frames are not a safe recovery boundary.
        let shouldEnterAwaitingKeyframe = (
            timedOutKeyframeCount > 0 ||
                timedOutPFrameCount > 0 ||
                timedOutExpectedPFrame ||
                missingExpectedPFrameGapTimedOut
        ) && !awaitingKeyframe

        if missingExpectedPFrameGapTimedOut {
            let expectedFrame = lastCompletedFrame &+ 1
            if let earliestBufferedFrame = pendingFrames
                .keys
                .filter({ isFrameNewer($0, than: lastCompletedFrame) })
                .min()
            {
                let gapFrames = earliestBufferedFrame &- expectedFrame
                MirageLogger.log(
                    .frameAssembly,
                    "Forward gap timed out: expected=\(expectedFrame) earliestBuffered=\(earliestBufferedFrame) gapFrames=\(gapFrames)"
                )
            }
        }

        return TimeoutCleanupResult(
            timedOutPFrames: timedOutPFrameCount,
            timedOutKeyframes: timedOutKeyframeCount,
            staleKeyframes: staleKeyframeCount,
            timedOutExpectedPFrame: timedOutExpectedPFrame,
            missingExpectedPFrameGapTimedOut: missingExpectedPFrameGapTimedOut,
            shouldEnterAwaitingKeyframe: shouldEnterAwaitingKeyframe
        )
    }

    private func enterKeyframeOnlyModeLocked() {
        beginAwaitingKeyframe()
        let framesToRelease = pendingFrames.filter { entry in
            let frame = entry.value
            if frame.isKeyframe { return isStaleKeyframeLocked(entry.key) }
            return true
        }
        for frame in framesToRelease.values {
            frame.buffer.release()
        }
        pendingFrames = pendingFrames.filter { entry in
            entry.value.isKeyframe && !isStaleKeyframeLocked(entry.key)
        }
    }

    private func hasTimedOutBufferedForwardGapLocked(
        now: Date,
        timeout: TimeInterval
    ) -> Bool {
        let expectedFrame = lastCompletedFrame &+ 1
        if let pendingExpectedFrame = pendingFrames[expectedFrame] {
            guard !pendingExpectedFrame.isKeyframe else { return false }
            guard !pendingExpectedFrame.isComplete else { return false }
        }

        guard let earliestBufferedForwardFrame = pendingFrames
            .filter({ entry in
                isFrameNewer(entry.key, than: lastCompletedFrame) && entry.value.isComplete
            })
            .min(by: { lhs, rhs in
                if lhs.key == rhs.key {
                    return lhs.value.receivedAt < rhs.value.receivedAt
                }
                return isFrameNewer(rhs.key, than: lhs.key)
            })
        else {
            return false
        }

        guard isFrameNewer(earliestBufferedForwardFrame.key, than: expectedFrame) else { return false }
        let gapReferenceTime = pendingFrames[expectedFrame]?.lastProgressAt ?? earliestBufferedForwardFrame.value.receivedAt
        return now.timeIntervalSince(gapReferenceTime) >= timeout
    }

    private func pFrameTimeoutLocked() -> TimeInterval {
        let frameInterval = 1.0 / Double(max(1, targetFrameRate))
        return min(
            pFrameTimeoutMaximum,
            max(pFrameTimeoutMinimum, frameInterval * pFrameTimeoutFrameIntervalBudget)
        )
    }

    private func severeForwardGapFrameThresholdLocked() -> UInt32 {
        let frameRate = max(1, targetFrameRate)
        let frameInterval = 1.0 / Double(frameRate)
        let timeout = min(
            pFrameTimeoutMaximum,
            max(pFrameTimeoutMinimum, frameInterval * severeForwardGapFrameIntervalBudget)
        )
        return max(3, UInt32(ceil(timeout / frameInterval)))
    }

    private func shouldPromotePendingKeyframeLocked(now: Date) -> Bool {
        guard hasDeliveredKeyframeAnchor, !awaitingKeyframe else { return false }

        let expectedFrame = lastCompletedFrame &+ 1
        guard pendingFrames[expectedFrame] == nil else { return false }

        guard let newestPendingKeyframe = pendingFrames
            .filter({ $0.value.isKeyframe && isFrameNewer($0.key, than: expectedFrame) })
            .max(by: { lhs, rhs in
                if lhs.key == rhs.key {
                    return lhs.value.lastProgressAt < rhs.value.lastProgressAt
                }
                return isFrameNewer(rhs.key, than: lhs.key)
            })
        else {
            return false
        }

        let elapsed = now.timeIntervalSince(newestPendingKeyframe.value.receivedAt)
        let progressRatio: Double = if newestPendingKeyframe.value.dataFragmentCount > 0 {
            Double(newestPendingKeyframe.value.receivedCount) /
                Double(newestPendingKeyframe.value.dataFragmentCount)
        } else {
            0
        }
        return elapsed >= pendingKeyframePromotionDelay ||
            progressRatio >= pendingKeyframePromotionProgressThreshold
    }

    private func promotePendingKeyframeLocked() {
        beginAwaitingKeyframe()
        let preservedKeyframes = pendingFrames.filter { $0.value.isKeyframe }
        for frame in pendingFrames.values where !frame.isKeyframe {
            frame.buffer.release()
        }
        pendingFrames = preservedKeyframes
    }

    private func enforceMemoryBudgetLocked() -> UInt64 {
        var evictedCount: UInt64 = 0

        func evict(_ frameNumber: UInt32) {
            guard let frame = pendingFrames.removeValue(forKey: frameNumber) else { return }
            frame.buffer.release()
            droppedFrameCount += 1
            memoryBudgetEvictionCount += 1
            evictedCount += 1
        }

        while pendingFrames.count > memoryBudget.maxPendingFrames,
              let frameNumber = memoryBudgetEvictionCandidateLocked() {
            evict(frameNumber)
        }

        while pendingKeyframeCountLocked() > memoryBudget.maxPendingKeyframes,
              let frameNumber = oldestPendingKeyframeLocked(excluding: bestPendingKeyframeNumberLocked()) {
            evict(frameNumber)
        }

        while pendingFrameBytesLocked() > memoryBudget.maxPendingBytes,
              pendingFrames.count > 1,
              let frameNumber = memoryBudgetEvictionCandidateLocked() {
            evict(frameNumber)
        }

        if evictedCount > 0 {
            enterKeyframeOnlyModeLocked()
            MirageLogger.client(
                "Frame reassembler memory budget evicted \(evictedCount) pending frame(s) for stream \(streamID); " +
                    "pendingBytes=\(pendingFrameBytesLocked()), pendingFrames=\(pendingFrames.count)"
            )
        }

        return evictedCount
    }

    private func memoryBudgetEvictionCandidateLocked() -> UInt32? {
        if let nonKeyframe = oldestPendingFrameNumberLocked(where: { _, frame in
            !frame.isKeyframe
        }) {
            return nonKeyframe
        }
        return oldestPendingKeyframeLocked(excluding: bestPendingKeyframeNumberLocked())
    }

    private func oldestPendingKeyframeLocked(excluding excludedFrameNumber: UInt32?) -> UInt32? {
        oldestPendingFrameNumberLocked { frameNumber, frame in
            frame.isKeyframe && frameNumber != excludedFrameNumber
        }
    }

    private func bestPendingKeyframeNumberLocked() -> UInt32? {
        let mostProgressed = pendingFrames
            .filter { $0.value.isKeyframe }
            .max { lhs, rhs in
                let lhsProgress = keyframeProgressRatioLocked(lhs.value)
                let rhsProgress = keyframeProgressRatioLocked(rhs.value)
                if lhsProgress != rhsProgress {
                    return lhsProgress < rhsProgress
                }
                if lhs.value.lastProgressAt != rhs.value.lastProgressAt {
                    return lhs.value.lastProgressAt < rhs.value.lastProgressAt
                }
                return isFrameNewer(rhs.key, than: lhs.key)
            }?
            .key
        if let mostProgressed,
           let frame = pendingFrames[mostProgressed],
           keyframeProgressRatioLocked(frame) >= pendingKeyframeProgressPreservationThreshold {
            return mostProgressed
        }
        if let newest = newestPendingKeyframeNumberLocked(),
           let newestFrame = pendingFrames[newest],
           newestFrame.retainedMemoryBytes <= memoryBudget.maxPendingBytes {
            return newest
        }
        return mostProgressed
    }

    private func newestPendingKeyframeNumberLocked() -> UInt32? {
        pendingFrames
            .filter { $0.value.isKeyframe }
            .max { lhs, rhs in
                if lhs.value.lastProgressAt != rhs.value.lastProgressAt {
                    return lhs.value.lastProgressAt < rhs.value.lastProgressAt
                }
                return isFrameNewer(rhs.key, than: lhs.key)
            }?
            .key
    }

    private func keyframeProgressRatioLocked(_ frame: PendingFrame) -> Double {
        guard frame.dataFragmentCount > 0 else { return 0 }
        return Double(frame.receivedCount) / Double(frame.dataFragmentCount)
    }

    private func oldestPendingFrameNumberLocked(
        where shouldInclude: (UInt32, PendingFrame) -> Bool
    )
    -> UInt32? {
        pendingFrames
            .filter { shouldInclude($0.key, $0.value) }
            .min { lhs, rhs in
                if lhs.value.receivedAt != rhs.value.receivedAt {
                    return lhs.value.receivedAt < rhs.value.receivedAt
                }
                return isFrameNewer(rhs.key, than: lhs.key)
            }?
            .key
    }

    private func pendingFrameBytesLocked() -> Int {
        pendingFrames.values.reduce(0) { $0 + $1.retainedMemoryBytes }
    }

    private func pendingKeyframeCountLocked() -> Int {
        pendingFrames.values.reduce(0) { $0 + ($1.isKeyframe ? 1 : 0) }
    }

    func shouldRequestKeyframe() -> Bool {
        lock.lock()
        let incompleteCount = pendingFrames.count
        lock.unlock()
        return incompleteCount > 5
    }

    func hasReceivedPackets() -> Bool {
        lock.lock()
        let received = totalPacketsReceived > 0
        lock.unlock()
        return received
    }

    func getDroppedFrameCount() -> UInt64 {
        lock.lock()
        let count = droppedFrameCount
        lock.unlock()
        return count
    }

    func snapshotMetrics() -> Metrics {
        lock.lock()
        let discardedPackets = packetsDiscardedOld +
            packetsDiscardedCRC +
            packetsDiscardedToken +
            packetsDiscardedAwaitingKeyframe +
            packetsDiscardedEpoch +
            packetsDiscardedDeliveredKeyframe
        let metrics = Metrics(
            framesDelivered: framesDelivered,
            lastCompletedFrame: lastCompletedFrame,
            totalPacketsReceived: totalPacketsReceived,
            droppedFrames: droppedFrameCount,
            discardedPackets: discardedPackets,
            pendingFrameCount: pendingFrames.count,
            pendingKeyframeCount: pendingKeyframeCountLocked(),
            pendingFrameBytes: pendingFrameBytesLocked(),
            frameBufferPoolRetainedBytes: bufferPool.retainedByteCount(),
            budgetEvictions: memoryBudgetEvictionCount
        )
        lock.unlock()
        return metrics
    }

    func trimForMemoryPressure() -> MemoryTrimResult {
        lock.lock()
        let evictedFrames = pendingFrames.count
        let releasedPendingBytes = pendingFrameBytesLocked()
        for frame in pendingFrames.values {
            frame.buffer.release()
        }
        pendingFrames.removeAll(keepingCapacity: false)
        if evictedFrames > 0 {
            droppedFrameCount += UInt64(evictedFrames)
            beginAwaitingKeyframe()
        }
        let purgedRetainedBytes = bufferPool.purgeRetainedBuffers()
        let result = MemoryTrimResult(
            evictedFrames: evictedFrames,
            releasedPendingBytes: releasedPendingBytes,
            purgedRetainedBytes: purgedRetainedBytes,
            awaitingKeyframe: awaitingKeyframe
        )
        lock.unlock()

        if evictedFrames > 0 || purgedRetainedBytes > 0 {
            MirageLogger.client(
                "Memory pressure trimmed \(evictedFrames) reassembler frame(s) for stream \(streamID); " +
                    "releasedPendingBytes=\(releasedPendingBytes), purgedRetainedBytes=\(purgedRetainedBytes)"
            )
        }

        return result
    }

    func trimPendingFramesForRecovery(reason: String) {
        lock.lock()
        let evictedFrames = pendingFrames.count
        let releasedPendingBytes = pendingFrameBytesLocked()
        for frame in pendingFrames.values {
            frame.buffer.release()
        }
        pendingFrames.removeAll(keepingCapacity: false)
        if evictedFrames > 0 {
            droppedFrameCount += UInt64(evictedFrames)
        }
        beginAwaitingKeyframe()
        lock.unlock()

        if evictedFrames > 0 {
            MirageLogger.client(
                "Recovery trimmed \(evictedFrames) reassembler frame(s) for stream \(streamID); " +
                    "reason=\(reason), releasedPendingBytes=\(releasedPendingBytes)"
            )
        }
    }

    func enterKeyframeOnlyMode() {
        lock.lock()
        enterKeyframeOnlyModeLocked()
        lock.unlock()
        MirageLogger.log(.frameAssembly, "Entering keyframe-only mode for stream \(streamID)")
    }

    func awaitingKeyframeDuration(now: CFAbsoluteTime) -> CFAbsoluteTime? {
        lock.lock()
        let duration: CFAbsoluteTime? = if awaitingKeyframe, awaitingKeyframeSince > 0 {
            now - awaitingKeyframeSince
        } else {
            nil
        }
        lock.unlock()
        return duration
    }

    func keyframeTimeoutSeconds() -> CFAbsoluteTime {
        lock.lock()
        let timeout = startupKeyframeTimeoutOverrideEnabled ? startupKeyframeTimeout : keyframeTimeout
        lock.unlock()
        return timeout
    }

    func setStartupKeyframeTimeoutOverrideEnabled(_ enabled: Bool) {
        lock.lock()
        startupKeyframeTimeoutOverrideEnabled = enabled
        lock.unlock()
    }

    func latestPacketReceivedTime() -> CFAbsoluteTime {
        lock.lock()
        let timestamp = lastPacketReceivedTime
        lock.unlock()
        return timestamp
    }

    func isAwaitingKeyframe() -> Bool {
        lock.lock()
        let awaiting = awaitingKeyframe
        lock.unlock()
        return awaiting
    }

    func latestPendingKeyframeProgress() -> PendingKeyframeProgress? {
        lock.lock()
        let progress = bestPendingKeyframeNumberLocked()
            .flatMap { frameNumber in
                pendingFrames[frameNumber].map { frame in
                    (frameNumber, frame)
                }
            }
            .map { frameNumber, frame in
                PendingKeyframeProgress(
                    frameNumber: frameNumber,
                    receivedCount: frame.receivedCount,
                    totalCount: frame.dataFragmentCount,
                    lastProgressTime: frame.lastProgressAt.timeIntervalSinceReferenceDate
                )
            }
        lock.unlock()
        return progress
    }

    func hasKeyframeAnchor() -> Bool {
        lock.lock()
        let hasAnchor = hasDeliveredKeyframeAnchor
        lock.unlock()
        return hasAnchor
    }

    func reset() {
        lock.lock()
        for frame in pendingFrames.values {
            frame.buffer.release()
        }
        pendingFrames.removeAll()
        lastCompletedFrame = 0
        lastDeliveredKeyframe = 0
        hasDeliveredKeyframeAnchor = false
        hasSignaledGapFrameLoss = false
        clearAwaitingKeyframe()
        droppedFrameCount = 0
        memoryBudgetEvictionCount = 0
        lastPacketReceivedTime = 0
        startupKeyframeTimeoutOverrideEnabled = false
        lock.unlock()
        MirageLogger.log(.frameAssembly, "Reassembler reset for stream \(streamID)")
    }

    private func beginAwaitingKeyframe() {
        if !awaitingKeyframe || awaitingKeyframeSince == 0 {
            awaitingKeyframe = true
            awaitingKeyframeSince = CFAbsoluteTimeGetCurrent()
        }
    }

    private func clearAwaitingKeyframe() {
        awaitingKeyframe = false
        awaitingKeyframeSince = 0
    }

    private func isStaleKeyframeLocked(_ frameNumber: UInt32) -> Bool {
        guard hasDeliveredKeyframeAnchor else { return false }
        if frameNumber == lastDeliveredKeyframe { return true }
        guard frameNumber < lastDeliveredKeyframe else { return false }
        return lastDeliveredKeyframe - frameNumber <= 1000
    }

    private func purgeStaleKeyframesLocked() {
        guard hasDeliveredKeyframeAnchor else { return }
        let staleFrames = pendingFrames.filter { entry in
            entry.value.isKeyframe && isStaleKeyframeLocked(entry.key)
        }
        for (frameNumber, frame) in staleFrames {
            pendingFrames.removeValue(forKey: frameNumber)
            frame.buffer.release()
            droppedFrameCount += 1
        }
    }

    private func resolvedFrameByteCount(header: FrameHeader, maxPayloadSize: Int) -> Int {
        let byteCount = Int(header.frameByteCount)
        if byteCount > 0 { return byteCount }
        let fragments = Int(header.fragmentCount)
        return max(0, fragments * maxPayloadSize)
    }

    private func resolvedDataFragmentCount(
        header: FrameHeader,
        frameByteCount: Int,
        maxPayloadSize: Int
    )
    -> Int {
        guard maxPayloadSize > 0 else { return Int(header.fragmentCount) }
        if frameByteCount > 0 { return (frameByteCount + maxPayloadSize - 1) / maxPayloadSize }
        return Int(header.fragmentCount)
    }

    private func parityIndexForDataFragment(fragmentIndex: Int, frame: PendingFrame) -> Int? {
        let parityCount = Int(frame.totalFragments) - frame.dataFragmentCount
        guard parityCount > 0 else { return nil }
        let blockSize = frame.fecBlockSize
        guard blockSize > 1 else { return nil }
        let blockIndex = fragmentIndex / blockSize
        guard blockIndex < parityCount else { return nil }
        return blockIndex
    }

    private func payloadLength(
        for fragmentIndex: Int,
        frameByteCount: Int,
        maxPayloadSize: Int
    )
    -> Int {
        guard maxPayloadSize > 0 else { return 0 }
        let start = fragmentIndex * maxPayloadSize
        let remaining = max(0, frameByteCount - start)
        return min(maxPayloadSize, remaining)
    }

    private func tryRecoverMissingFragment(
        frame: PendingFrame,
        parityIndex: Int,
        frameByteCount: Int
    ) {
        guard let parityData = frame.parityFragments[parityIndex] else { return }
        let blockSize = frame.fecBlockSize
        guard blockSize > 1 else { return }

        let blockStart = parityIndex * blockSize
        let blockEnd = min(blockStart + blockSize, frame.dataFragmentCount)
        guard blockStart < blockEnd else { return }

        var missingIndex: Int?
        for index in blockStart ..< blockEnd {
            if !frame.receivedMap[index] {
                if missingIndex != nil { return }
                missingIndex = index
            }
        }
        guard let recoverIndex = missingIndex else { return }

        let effectiveFrameByteCount = frameByteCount > 0 ? frameByteCount : frame.expectedTotalBytes
        let expectedLength = payloadLength(
            for: recoverIndex,
            frameByteCount: effectiveFrameByteCount,
            maxPayloadSize: maxPayloadSize
        )
        guard expectedLength > 0 else { return }

        var recovered = Data(repeating: 0, count: expectedLength)
        recovered.withUnsafeMutableBytes { recoveredBytes in
            let recoveredPtr = recoveredBytes.bindMemory(to: UInt8.self)
            guard let recoveredBase = recoveredPtr.baseAddress else { return }
            parityData.withUnsafeBytes { parityBytes in
                let parityPtr = parityBytes.bindMemory(to: UInt8.self)
                guard let parityBase = parityPtr.baseAddress else { return }
                let copyLength = min(parityData.count, expectedLength)
                recoveredBase.update(from: parityBase, count: copyLength)
            }
            frame.buffer.withUnsafeBytes { buffer in
                guard let bufferBase = buffer.baseAddress else { return }
                let bufferPtr = bufferBase.assumingMemoryBound(to: UInt8.self)
                for index in blockStart ..< blockEnd where index != recoverIndex && frame.receivedMap[index] {
                    let fragmentLength = payloadLength(
                        for: index,
                        frameByteCount: effectiveFrameByteCount,
                        maxPayloadSize: maxPayloadSize
                    )
                    guard fragmentLength > 0 else { continue }
                    let offset = index * maxPayloadSize
                    let source = bufferPtr.advanced(by: offset)
                    let bytesToXor = min(fragmentLength, expectedLength)
                    for i in 0 ..< bytesToXor {
                        recoveredBase[i] ^= source[i]
                    }
                }
            }
        }

        let offset = recoverIndex * maxPayloadSize
        frame.buffer.write(recovered, at: offset)
        frame.receivedMap[recoverIndex] = true
        frame.receivedCount += 1
        if frame.isKeyframe || recoverIndex != 0 || parityIndex != 0 {
            MirageLogger.log(.frameAssembly, "Recovered fragment \(recoverIndex) via FEC (block \(parityIndex))")
        }
    }
}
