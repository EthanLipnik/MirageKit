//
//  HEVCDecoder+Packets.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  HEVC decoder extensions.
//

import Foundation
import CoreGraphics

extension FrameReassembler {
    func setFrameHandler(_ handler: @escaping @Sendable (StreamID, Data, Bool, UInt64, CGRect, @escaping @Sendable () -> Void) -> Void) {
        lock.lock()
        onFrameComplete = handler
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
        var completedFrame: CompletedFrame?
        var completionHandler: (@Sendable (StreamID, Data, Bool, UInt64, CGRect, @escaping @Sendable () -> Void) -> Void)?

        let frameNumber = header.frameNumber
        let isKeyframePacket = header.flags.contains(.keyframe)
        lock.lock()
        totalPacketsReceived += 1

        // Log stats every 1000 packets
        if totalPacketsReceived - lastStatsLog >= 1000 {
            lastStatsLog = totalPacketsReceived
            MirageLogger.log(.frameAssembly, "STATS: packets=\(totalPacketsReceived), framesDelivered=\(framesDelivered), pending=\(pendingFrames.count), discarded(old=\(packetsDiscardedOld), crc=\(packetsDiscardedCRC), token=\(packetsDiscardedToken), epoch=\(packetsDiscardedEpoch), awaitKeyframe=\(packetsDiscardedAwaitingKeyframe))")
        }

        if header.epoch != currentEpoch {
            if isKeyframePacket {
                resetForEpoch(header.epoch, reason: "epoch mismatch")
            } else {
                packetsDiscardedEpoch += 1
                beginAwaitingKeyframe()
                lock.unlock()
                return
            }
        }

        if header.flags.contains(.discontinuity) {
            if isKeyframePacket {
                resetForEpoch(header.epoch, reason: "discontinuity")
            } else {
                packetsDiscardedEpoch += 1
                beginAwaitingKeyframe()
                lock.unlock()
                return
            }
        }

        // Validate dimension token to reject old-dimension frames after resize.
        // Keyframes always update the expected token since they establish new dimensions.
        // P-frames with mismatched tokens are silently discarded.
        if dimensionTokenValidationEnabled {
            if isKeyframePacket {
                // Keyframes update the expected token - they carry new VPS/SPS/PPS
                if header.dimensionToken != expectedDimensionToken {
                    MirageLogger.log(.frameAssembly, "Keyframe updated dimension token from \(expectedDimensionToken) to \(header.dimensionToken)")
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

        // Validate CRC32 checksum to detect corrupted packets
        let calculatedCRC = CRC32.calculate(data)
        if calculatedCRC != header.checksum {
            packetsDiscardedCRC += 1
            MirageLogger.log(.frameAssembly, "CRC mismatch for frame \(frameNumber) fragment \(header.fragmentIndex) - discarding (expected \(header.checksum), got \(calculatedCRC))")
            lock.unlock()
            return
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

        let totalFragments = Int(header.fragmentCount)
        let frame: PendingFrame
        if let existingFrame = pendingFrames[frameNumber] {
            frame = existingFrame
        } else {
            let capacity = totalFragments * maxPayloadSize
            let buffer = bufferPool.acquire(capacity: capacity)
            frame = PendingFrame(
                buffer: buffer,
                receivedMap: Array(repeating: false, count: totalFragments),
                receivedCount: 0,
                totalFragments: header.fragmentCount,
                isKeyframe: isKeyframePacket,
                timestamp: header.timestamp,
                receivedAt: Date(),
                contentRect: header.contentRect,
                expectedTotalBytes: capacity
            )
            pendingFrames[frameNumber] = frame
        }

        // Update keyframe flag if this packet has it (in case fragments arrive out of order)
        if isKeyframePacket && !frame.isKeyframe {
            frame.isKeyframe = true
        }

        // NOTE: We intentionally do NOT discard older incomplete keyframes when a newer one starts.
        // During network congestion, multiple keyframes may arrive simultaneously. Discarding
        // partially-complete keyframes (even 70%+) in favor of new ones creates a cascade where
        // ALL keyframes fail. Instead, let each keyframe complete or timeout naturally via
        // cleanupOldFrames(). The timeout-based approach is more robust.

        // Store fragment
        let fragmentIndex = Int(header.fragmentIndex)
        if fragmentIndex >= 0 && fragmentIndex < frame.receivedMap.count {
            if !frame.receivedMap[fragmentIndex] {
                let offset = fragmentIndex * maxPayloadSize
                frame.buffer.write(data, at: offset)
                frame.receivedMap[fragmentIndex] = true
                frame.receivedCount += 1
                if fragmentIndex == frame.receivedMap.count - 1 {
                    let end = offset + data.count
                    frame.expectedTotalBytes = min(end, frame.buffer.capacity)
                }
            }
        }

        // Log keyframe assembly progress for diagnostics
        if frame.isKeyframe {
            let receivedCount = frame.receivedCount
            let totalCount = Int(frame.totalFragments)
            // Log at key milestones: first packet, 25%, 50%, 75%, and when nearly complete
            if receivedCount == 1 || receivedCount == totalCount / 4 || receivedCount == totalCount / 2 ||
               receivedCount == (totalCount * 3) / 4 || receivedCount == totalCount - 1 {
                MirageLogger.log(.frameAssembly, "Keyframe \(frameNumber): \(receivedCount)/\(totalCount) fragments received")
            }
        }

        // Check if frame is complete
        if frame.receivedCount == Int(frame.totalFragments) {
            completedFrame = completeFrameLocked(frameNumber: frameNumber, frame: frame)
            completionHandler = onFrameComplete
        }

        // Clean up old pending frames
        cleanupOldFramesLocked()
        lock.unlock()

        if let completedFrame, let completionHandler {
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

    private struct CompletedFrame {
        let data: Data
        let isKeyframe: Bool
        let timestamp: UInt64
        let contentRect: CGRect
        let releaseBuffer: (@Sendable () -> Void)
    }

    private func completeFrameLocked(frameNumber: UInt32, frame: PendingFrame) -> CompletedFrame? {
        // Frame skipping logic: determine if we should deliver this frame
        let shouldDeliver: Bool

        if frame.isKeyframe {
            // Always deliver keyframes unless a newer keyframe was already delivered
            shouldDeliver = frameNumber > lastDeliveredKeyframe || lastDeliveredKeyframe == 0
            if shouldDeliver {
                lastDeliveredKeyframe = frameNumber
            }
        } else {
            // For P-frames: only deliver if newer than last completed frame
            // and after the last keyframe (decoder needs the reference)
            shouldDeliver = frameNumber > lastCompletedFrame && frameNumber > lastDeliveredKeyframe
        }

        if shouldDeliver {
            // Discard any pending frames older than this one
            discardOlderPendingFramesLocked(olderThan: frameNumber)

            lastCompletedFrame = frameNumber
            pendingFrames.removeValue(forKey: frameNumber)

            framesDelivered += 1
            if frame.isKeyframe {
                MirageLogger.log(.frameAssembly, "Delivering keyframe \(frameNumber) (\(frame.expectedTotalBytes) bytes)")
                clearAwaitingKeyframe()
            }
            let output = frame.buffer.finalize(length: frame.expectedTotalBytes)
            let buffer = frame.buffer
            let releaseBuffer: @Sendable () -> Void = { buffer.release() }
            return CompletedFrame(
                data: output,
                isKeyframe: frame.isKeyframe,
                timestamp: frame.timestamp,
                contentRect: frame.contentRect,
                releaseBuffer: releaseBuffer
            )
        } else {
            // This frame arrived too late - a newer frame was already delivered
            if frame.isKeyframe {
                MirageLogger.log(.frameAssembly, "WARNING: Keyframe \(frameNumber) NOT delivered (lastDeliveredKeyframe=\(lastDeliveredKeyframe))")
            }
            pendingFrames.removeValue(forKey: frameNumber)
            frame.buffer.release()
            droppedFrameCount += 1
            return nil
        }
    }

    private func discardOlderPendingFramesLocked(olderThan frameNumber: UInt32) {
        let framesToDiscard = pendingFrames.keys.filter { pendingFrameNumber in
            // Discard P-frames older than the one we're about to deliver
            // Handle wrap-around: if difference is huge, it's probably wrap-around
            guard pendingFrameNumber < frameNumber && frameNumber - pendingFrameNumber < 1000 else {
                return false
            }
            // NEVER discard pending keyframes - they're critical for decoder recovery
            // Keyframes are large (500+ packets) and take longer to arrive than P-frames
            // If we discard an incomplete keyframe, the decoder will be stuck
            if let frame = pendingFrames[pendingFrameNumber], frame.isKeyframe {
                return false
            }
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
        clearAwaitingKeyframe()
        packetsDiscardedAwaitingKeyframe = 0
        MirageLogger.log(.frameAssembly, "Epoch \(epoch) reset (\(reason)) for stream \(streamID)")
    }

    private func cleanupOldFramesLocked() {
        let now = Date()
        // P-frame timeout: 500ms - allows time for UDP packet jitter without dropping frames
        let pFrameTimeout: TimeInterval = 0.5
        // Keyframes are 600-900 packets and critical for recovery
        // They need much more time to complete than small P-frames

        var timedOutCount: UInt64 = 0
        var framesToRemove: [UInt32] = []
        for (frameNumber, frame) in pendingFrames {
            let timeout = frame.isKeyframe ? keyframeTimeout : pFrameTimeout
            let shouldKeep = now.timeIntervalSince(frame.receivedAt) < timeout
            if !shouldKeep {
                // Log timeout with fragment completion info for debugging
                let receivedCount = frame.receivedCount
                let totalCount = frame.totalFragments
                let isKeyframe = frame.isKeyframe
                MirageLogger.log(.frameAssembly, "Frame \(frameNumber) timed out: \(receivedCount)/\(totalCount) fragments\(isKeyframe ? " (KEYFRAME)" : "")")
                timedOutCount += 1
            }
            if !shouldKeep {
                framesToRemove.append(frameNumber)
            }
        }
        for frameNumber in framesToRemove {
            if let frame = pendingFrames.removeValue(forKey: frameNumber) {
                frame.buffer.release()
            }
        }
        droppedFrameCount += timedOutCount
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

    func enterKeyframeOnlyMode() {
        lock.lock()
        beginAwaitingKeyframe()
        let framesToRelease = pendingFrames.filter { !$0.value.isKeyframe }
        for frame in framesToRelease.values {
            frame.buffer.release()
        }
        pendingFrames = pendingFrames.filter { $0.value.isKeyframe }
        lock.unlock()
        MirageLogger.log(.frameAssembly, "Entering keyframe-only mode for stream \(streamID)")
    }

    func awaitingKeyframeDuration(now: CFAbsoluteTime) -> CFAbsoluteTime? {
        lock.lock()
        let duration: CFAbsoluteTime?
        if awaitingKeyframe, awaitingKeyframeSince > 0 {
            duration = now - awaitingKeyframeSince
        } else {
            duration = nil
        }
        lock.unlock()
        return duration
    }

    func keyframeTimeoutSeconds() -> CFAbsoluteTime {
        keyframeTimeout
    }

    func reset() {
        lock.lock()
        for frame in pendingFrames.values {
            frame.buffer.release()
        }
        pendingFrames.removeAll()
        lastCompletedFrame = 0
        lastDeliveredKeyframe = 0
        clearAwaitingKeyframe()
        droppedFrameCount = 0
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
}
