//
//  HEVCDecoder+Packets.swift
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
        UInt64,
        CGRect,
        @escaping @Sendable () -> Void
    )
        -> Void) {
        lock.lock()
        onFrameComplete = handler
        lock.unlock()
    }

    func setFrameLossHandler(_ handler: @escaping @Sendable (StreamID) -> Void) {
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

    func processPacket(_ data: Data, header: FrameHeader) {
        var completedFrames: [CompletedFrame] = []
        var completionHandler: (@Sendable (StreamID, Data, Bool, UInt64, CGRect, @escaping @Sendable () -> Void)
            -> Void)?
        var shouldSignalFrameLoss = false

        let frameNumber = header.frameNumber
        let isKeyframePacket = header.flags.contains(.keyframe)
        lock.lock()
        lastPacketReceivedTime = CFAbsoluteTimeGetCurrent()
        totalPacketsReceived += 1

        // Log stats every 1000 packets
        if totalPacketsReceived - lastStatsLog >= 1000 {
            lastStatsLog = totalPacketsReceived
            MirageLogger.log(
                .frameAssembly,
                "STATS: packets=\(totalPacketsReceived), framesDelivered=\(framesDelivered), pending=\(pendingFrames.count), discarded(old=\(packetsDiscardedOld), deliveredKeyframe=\(packetsDiscardedDeliveredKeyframe), crc=\(packetsDiscardedCRC), token=\(packetsDiscardedToken), epoch=\(packetsDiscardedEpoch), awaitKeyframe=\(packetsDiscardedAwaitingKeyframe))"
            )
        }

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

        // Validate dimension token to reject old-dimension frames after resize.
        // Keyframes always update the expected token since they establish new dimensions.
        // P-frames with mismatched tokens are silently discarded.
        if dimensionTokenValidationEnabled {
            if isKeyframePacket {
                // Keyframes update the expected token - they carry new VPS/SPS/PPS
                if header.dimensionToken != expectedDimensionToken {
                    MirageLogger.log(
                        .frameAssembly,
                        "Keyframe updated dimension token from \(expectedDimensionToken) to \(header.dimensionToken)"
                    )
                    expectedDimensionToken = header.dimensionToken
                }
            } else if header.dimensionToken != expectedDimensionToken {
                // P-frame with wrong token - silently discard (old dimensions)
                packetsDiscardedToken += 1
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
            frame = PendingFrame(
                buffer: buffer,
                receivedMap: Array(repeating: false, count: dataFragmentCount),
                receivedCount: 0,
                totalFragments: header.fragmentCount,
                dataFragmentCount: dataFragmentCount,
                isKeyframe: isKeyframePacket,
                timestamp: header.timestamp,
                receivedAt: Date(),
                contentRect: header.contentRect,
                expectedTotalBytes: usesHeaderByteCount ? frameByteCount : capacity
            )
            pendingFrames[frameNumber] = frame
        }

        // Update keyframe flag if this packet has it (in case fragments arrive out of order)
        if isKeyframePacket && !frame.isKeyframe { frame.isKeyframe = true }

        // NOTE: We intentionally do NOT discard older incomplete keyframes when a newer one starts.
        // During network congestion, multiple keyframes may arrive simultaneously. Discarding
        // partially-complete keyframes (even 70%+) in favor of new ones creates a cascade where
        // ALL keyframes fail. Instead, let each keyframe complete or timeout naturally via
        // cleanupOldFrames(). The timeout-based approach is more robust.

        // Store fragment
        let fragmentIndex = Int(header.fragmentIndex)
        let isParityFragment = header.flags.contains(.fecParity) || fragmentIndex >= frame.dataFragmentCount
        if isParityFragment {
            let parityIndex = max(0, fragmentIndex - frame.dataFragmentCount)
            if frame.parityFragments[parityIndex] == nil {
                frame.parityFragments[parityIndex] = data
                frame.receivedParityCount += 1
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
                if drainResult.shouldSignalFrameLoss {
                    shouldSignalFrameLoss = true
                }
            }
            if completionResult.shouldSignalFrameLoss {
                shouldSignalFrameLoss = true
            }
            completionHandler = onFrameComplete
        }

        // Clean up old pending frames
        let timeoutResult = cleanupOldFramesLocked()
        if timeoutResult.shouldEnterAwaitingKeyframe {
            beginAwaitingKeyframe()
            MirageLogger.log(
                .frameAssembly,
                "Entering keyframe wait after timeout: pFrame=\(timeoutResult.timedOutPFrames), keyframe=\(timeoutResult.timedOutKeyframes), anchor=\(hasDeliveredKeyframeAnchor)"
            )
        }
        if timeoutResult.timedOutPFrames + timeoutResult.timedOutKeyframes > 0 {
            shouldSignalFrameLoss = true
        }
        if timeoutResult.missingExpectedPFrameGapTimedOut, !hasSignaledGapFrameLoss {
            shouldSignalFrameLoss = true
            hasSignaledGapFrameLoss = true
        }
        lock.unlock()

        if shouldSignalFrameLoss {
            if let onFrameLoss { onFrameLoss(streamID) }
        }

        if !completedFrames.isEmpty, let completionHandler {
            for completedFrame in completedFrames {
                completionHandler(
                    streamID,
                    completedFrame.data,
                    completedFrame.isKeyframe,
                    completedFrame.timestamp,
                    completedFrame.contentRect,
                    completedFrame.releaseBuffer
                )
            }
        }
    }

    private struct CompletedFrame {
        let data: Data
        let isKeyframe: Bool
        let timestamp: UInt64
        let contentRect: CGRect
        let releaseBuffer: @Sendable () -> Void
    }

    private struct FrameCompletionResult {
        let frame: CompletedFrame?
        let shouldSignalFrameLoss: Bool
        let retainedForInOrderDelivery: Bool
    }

    private struct DrainCompletionResult {
        let frames: [CompletedFrame]
        let shouldSignalFrameLoss: Bool
    }

    private struct TimeoutCleanupResult {
        let timedOutPFrames: UInt64
        let timedOutKeyframes: UInt64
        let staleKeyframes: UInt64
        let missingExpectedPFrameGapTimedOut: Bool
        let shouldEnterAwaitingKeyframe: Bool

        var shouldSignalFrameLoss: Bool {
            timedOutPFrames + timedOutKeyframes > 0 || missingExpectedPFrameGapTimedOut
        }
    }

    private func completeFrameLocked(frameNumber: UInt32, frame: PendingFrame) -> FrameCompletionResult {
        // Frame skipping logic: determine if we should deliver this frame
        let shouldDeliver: Bool
        let shouldSignalFrameLoss = false
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
                    shouldSignalFrameLoss: false,
                    retainedForInOrderDelivery: false
                )
            }
            let expectedNextFrame = lastCompletedFrame &+ 1
            let isForwardFrame = isFrameNewer(frameNumber, than: lastCompletedFrame)
            let isAfterKeyframeAnchor = isFrameNewer(frameNumber, than: lastDeliveredKeyframe)
            let hasForwardGap = isForwardFrame && isFrameNewer(frameNumber, than: expectedNextFrame)

            if hasForwardGap {
                shouldDeliver = false
                retainedForInOrderDelivery = true
                let gapFrames = frameNumber &- expectedNextFrame
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
                clearAwaitingKeyframe()
            }
            let output = frame.buffer.finalize(length: frame.expectedTotalBytes)

            // Diagnostic: log CRC32 of reassembled P-frames (throttled to every 60th)
            if !frame.isKeyframe {
                diagnosticCRCLogCounter += 1
                if diagnosticCRCLogCounter % 60 == 1 {
                    let crc = CRC32.calculate(output)
                    let header = output.prefix(16).map { String(format: "%02X", $0) }.joined(separator: " ")
                    MirageLogger.log(
                        .frameAssembly,
                        "Reassembled P-frame CRC=\(String(format: "%08X", crc)), size=\(output.count), expected=\(frame.expectedTotalBytes), header: \(header)"
                    )
                }
            }

            let buffer = frame.buffer
            let releaseBuffer: @Sendable () -> Void = { buffer.release() }
            return FrameCompletionResult(
                frame: CompletedFrame(
                    data: output,
                    isKeyframe: frame.isKeyframe,
                    timestamp: frame.timestamp,
                    contentRect: frame.contentRect,
                    releaseBuffer: releaseBuffer
                ),
                shouldSignalFrameLoss: shouldSignalFrameLoss,
                retainedForInOrderDelivery: false
            )
        } else {
            if retainedForInOrderDelivery {
                return FrameCompletionResult(
                    frame: nil,
                    shouldSignalFrameLoss: shouldSignalFrameLoss,
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
                shouldSignalFrameLoss: shouldSignalFrameLoss,
                retainedForInOrderDelivery: false
            )
        }
    }

    private func drainDeliverableFramesLocked() -> DrainCompletionResult {
        var drainedFrames: [CompletedFrame] = []
        var shouldSignalFrameLoss = false

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
            if completionResult.shouldSignalFrameLoss {
                shouldSignalFrameLoss = true
            }
            if completionResult.retainedForInOrderDelivery {
                break
            }
        }

        return DrainCompletionResult(
            frames: drainedFrames,
            shouldSignalFrameLoss: shouldSignalFrameLoss
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
        // P-frame timeout: 500ms - allows time for UDP packet jitter without dropping frames
        let pFrameTimeout: TimeInterval = 0.5
        // Keyframes are 600-900 packets and critical for recovery
        // They need much more time to complete than small P-frames

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
            let timeout = frame.isKeyframe ? keyframeTimeout : pFrameTimeout
            let shouldKeep = now.timeIntervalSince(frame.receivedAt) < timeout
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

        // Enter keyframe wait when a keyframe times out, or when the next expected P-frame
        // times out, or when a buffered forward gap persists without the expected frame ever arriving.
        let shouldEnterAwaitingKeyframe = (
            timedOutKeyframeCount > 0 ||
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
            missingExpectedPFrameGapTimedOut: missingExpectedPFrameGapTimedOut,
            shouldEnterAwaitingKeyframe: shouldEnterAwaitingKeyframe
        )
    }

    private func hasTimedOutBufferedForwardGapLocked(
        now: Date,
        timeout: TimeInterval
    ) -> Bool {
        let expectedFrame = lastCompletedFrame &+ 1
        guard pendingFrames[expectedFrame] == nil else { return false }

        guard let earliestBufferedForwardFrame = pendingFrames
            .filter({ isFrameNewer($0.key, than: lastCompletedFrame) })
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
        return now.timeIntervalSince(earliestBufferedForwardFrame.value.receivedAt) >= timeout
    }

    func shouldRequestKeyframe() -> Bool {
        lock.lock()
        let incompleteCount = pendingFrames.count
        lock.unlock()
        return incompleteCount > 5
    }

    func getDroppedFrameCount() -> UInt64 {
        lock.lock()
        let count = droppedFrameCount
        lock.unlock()
        return count
    }

    func snapshotMetrics() -> Metrics {
        lock.lock()
        let metrics = Metrics(framesDelivered: framesDelivered, droppedFrames: droppedFrameCount)
        lock.unlock()
        return metrics
    }

    func enterKeyframeOnlyMode() {
        lock.lock()
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
        keyframeTimeout
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
        lastPacketReceivedTime = 0
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
        let blockSize = frame.isKeyframe ? keyframeFECBlockSize : pFrameFECBlockSize
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
        let blockSize = frame.isKeyframe ? keyframeFECBlockSize : pFrameFECBlockSize
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
