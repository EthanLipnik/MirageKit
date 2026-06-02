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
        lock.lock()
        onFrameCompleteWithProvenance = handler
        lock.unlock()
    }

    func setFrameHandler(_ handler: @escaping @Sendable (
        StreamID,
        Data,
        Bool,
        UInt32,
        UInt64,
        CGRect,
        @escaping @Sendable () -> Void
    )
        -> Void) {
        setFrameHandler { streamID, data, isKeyframe, frameNumber, timestamp, _, _, contentRect, release in
            handler(streamID, data, isKeyframe, frameNumber, timestamp, contentRect, release)
        }
    }

    func setFrameLossHandler(_ handler: @escaping @Sendable (StreamID, FrameLossReason) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        onFrameLoss = FrameLossHandler(handler)
    }

    func updateExpectedDimensionToken(_ token: UInt16) {
        lock.lock()
        do {
            defer { lock.unlock() }
            expectedDimensionToken = token
            dimensionTokenValidationEnabled = true
        }
        MirageLogger.log(.frameAssembly, "Expected dimension token updated to \(token) for stream \(streamID)")
    }

    func setTargetFrameRate(_ frameRate: Int) {
        let sanitizedFrameRate = max(1, min(240, frameRate))
        lock.lock()
        let previousFrameRate: Int
        do {
            defer { lock.unlock() }
            previousFrameRate = targetFrameRate
            targetFrameRate = sanitizedFrameRate
        }

        guard previousFrameRate != sanitizedFrameRate else { return }
        MirageLogger.log(.frameAssembly, "Reassembler target frame rate updated to \(sanitizedFrameRate)fps for stream \(streamID)")
    }

    func setLatencyMode(_ latencyMode: MirageStreamLatencyMode) {
        lock.lock()
        let previousLatencyMode: MirageStreamLatencyMode
        do {
            defer { lock.unlock() }
            previousLatencyMode = self.latencyMode
            self.latencyMode = latencyMode
        }

        guard previousLatencyMode != latencyMode else { return }
        MirageLogger.log(
            .frameAssembly,
            "Reassembler latency mode updated to \(latencyMode.rawValue) for stream \(streamID)"
        )
    }

    func setTransportPathKind(_ pathKind: MirageNetworkPathKind) {
        lock.lock()
        let previousPathKind: MirageNetworkPathKind
        do {
            defer { lock.unlock() }
            previousPathKind = transportPathKind
            transportPathKind = pathKind
        }

        guard previousPathKind != pathKind else { return }
        MirageLogger.log(
            .frameAssembly,
            "Reassembler path kind updated to \(pathKind.rawValue) for stream \(streamID)"
        )
    }

    func setMediaPathProfile(_ profile: MirageMediaPathProfile) {
        lock.lock()
        let previousProfile: MirageMediaPathProfile
        do {
            defer { lock.unlock() }
            previousProfile = mediaPathProfile
            mediaPathProfile = profile
        }

        guard previousProfile != profile else { return }
        MirageLogger.log(
            .frameAssembly,
            "Reassembler media path profile updated to \(profile.rawValue) for stream \(streamID)"
        )
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
            @escaping @Sendable () -> Void
        )
            -> Void)?
        var legacyCompletionHandler: (@Sendable (
            StreamID,
            Data,
            Bool,
            UInt32,
            UInt64,
            CGRect,
            @escaping @Sendable () -> Void
        )
            -> Void)?
        var shouldSignalFrameLoss = false
        var frameLossReason: FrameLossReason?

        let frameNumber = header.frameNumber
        let isKeyframePacket = header.flags.contains(.keyframe)
        let packetReceivedAt = Date()
        lock.lock()
        lastPacketReceivedTime = packetReceivedAt.timeIntervalSinceReferenceDate
        totalPacketsReceived += 1

        let epochIsNewer = isEpochNewer(header.epoch, than: currentEpoch)
        let epochIsCurrentOrNewer = header.epoch == currentEpoch || epochIsNewer

        if header.epoch != currentEpoch {
            if isKeyframePacket, epochIsNewer { resetForEpoch(header.epoch, reason: "epoch mismatch") } else {
                beginAwaitingKeyframe()
                lock.unlock()
                return
            }
        }

        if header.flags.contains(.discontinuity) {
            if isKeyframePacket, epochIsCurrentOrNewer { resetForEpoch(header.epoch, reason: "discontinuity") } else {
                beginAwaitingKeyframe()
                lock.unlock()
                return
            }
        }

        if isKeyframePacket, isStaleKeyframeLocked(frameNumber) {
            lock.unlock()
            return
        }

        // Validate dimension tokens to reject packets from old resize generations.
        // The expected token is controlled by resize/window-selection state; packets
        // must not advance it because stale keyframes can arrive after a new geometry.
        if dimensionTokenValidationEnabled {
            if header.dimensionToken != expectedDimensionToken {
                if isKeyframePacket {
                    MirageLogger.log(
                        .frameAssembly,
                        "Discarding keyframe \(frameNumber) with dimension token \(header.dimensionToken); " +
                            "expected \(expectedDimensionToken), epoch=\(header.epoch), currentEpoch=\(currentEpoch)"
                    )
                    beginAwaitingKeyframe()
                }
                lock.unlock()
                return
            }
        }

        if awaitingKeyframe,
           !isKeyframePacket,
           !shouldBufferNonKeyframeWhileAwaitingKeyframeLocked(frameNumber: frameNumber) {
            lock.unlock()
            return
        }

        // Encrypted packets use AEAD integrity; unencrypted packets keep mandatory CRC validation.
        if !header.flags.contains(.encryptedPayload) {
            let calculatedCRC = CRC32.calculate(data)
            if calculatedCRC != header.checksum {
                packetsDiscardedCRC += 1
                MirageLogger.log(
                    .frameAssembly,
                    "CRC mismatch for frame \(frameNumber) fragment \(header.fragmentIndex) - discarding (expected \(header.checksum), got \(calculatedCRC))"
                )
                lock.unlock()
                return
            }
        }

        // Skip old P-frames, but NEVER skip keyframe packets.
        // Keyframes are large (400+ packets) and take longer to transmit than small P-frames.
        // P-frames sent after a keyframe may complete before the keyframe finishes.
        // If we skip "old" keyframe packets, recovery becomes impossible.
        let isOldFrame = frameNumber < lastCompletedFrame && lastCompletedFrame - frameNumber < 1000
        if isOldFrame && !isKeyframePacket {
            lock.unlock()
            return
        }

        guard let assemblyPlan = validatedFrameAssemblyPlan(header: header) else {
            droppedFrameCount += 1
            MirageLogger.log(
                .frameAssembly,
                "Dropping frame \(frameNumber) fragment \(header.fragmentIndex): invalid or over-budget assembly header"
            )
            lock.unlock()
            return
        }

        let frameByteCount = assemblyPlan.frameByteCount
        let dataFragmentCount = assemblyPlan.dataFragmentCount
        let usesHeaderByteCount = frameByteCount > 0
        let frame: PendingFrame
        if let existingFrame = pendingFrames[frameNumber] { frame = existingFrame } else {
            let buffer = bufferPool.acquire(capacity: assemblyPlan.bufferCapacity)
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
                expectedTotalBytes: usesHeaderByteCount ? frameByteCount : assemblyPlan.bufferCapacity
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
            completionHandler = onFrameCompleteWithProvenance
            legacyCompletionHandler = onFrameComplete
        }

        // Clean up old pending frames
        let timeoutResult = cleanupOldFramesLocked()
        if timeoutResult.shouldEnterAwaitingKeyframe {
            beginKeyframeWaitLocked()
            MirageLogger.log(
                .frameAssembly,
                "Entering keyframe wait after timeout: pFrame=\(timeoutResult.timedOutPFrames), " +
                    "keyframe=\(timeoutResult.timedOutKeyframes), " +
                    "incomplete=\(timeoutResult.incompleteFrameTimeouts), " +
                    "noProgress=\(timeoutResult.incompleteFrameNoProgressTimeouts), " +
                    "lifetime=\(timeoutResult.incompleteFrameLifetimeTimeouts), " +
                    "missingFragments=\(timeoutResult.missingFragmentTimeouts), " +
                    "forwardGap=\(timeoutResult.forwardGapTimeouts), " +
                    "anchor=\(hasDeliveredKeyframeAnchor)"
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
        if timeoutResult.skippedForwardGap {
            let drainResult = drainDeliverableFramesLocked()
            if !drainResult.frames.isEmpty {
                completedFrames.append(contentsOf: drainResult.frames)
            }
            if let drainLossReason = drainResult.frameLossReason {
                shouldSignalFrameLoss = true
                frameLossReason = frameLossReason ?? drainLossReason
            }
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
                onFrameLoss(streamID: streamID, reason: frameLossReason ?? .timeout)
            }
        }

        dispatchCompletedFrames(completedFrames, using: completionHandler, legacyHandler: legacyCompletionHandler)
    }

    private func dispatchCompletedFrames(
        _ completedFrames: [CompletedFrame],
        using completionHandler: (@Sendable (
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
            -> Void)?,
        legacyHandler: (@Sendable (
            StreamID,
            Data,
            Bool,
            UInt32,
            UInt64,
            CGRect,
            @escaping @Sendable () -> Void
        )
            -> Void)?
    ) {
        guard !completedFrames.isEmpty, completionHandler != nil || legacyHandler != nil else { return }
        for completedFrame in completedFrames {
            if let completionHandler {
                completionHandler(
                    streamID,
                    completedFrame.data,
                    completedFrame.isKeyframe,
                    completedFrame.frameNumber,
                    completedFrame.timestamp,
                    completedFrame.epoch,
                    completedFrame.dimensionToken,
                    completedFrame.contentRect,
                    completedFrame.releaseBuffer
                )
            } else if let legacyHandler {
                legacyHandler(
                streamID,
                completedFrame.data,
                completedFrame.isKeyframe,
                completedFrame.frameNumber,
                completedFrame.timestamp,
                completedFrame.contentRect,
                completedFrame.releaseBuffer
                )
            }
        }
    }

}
