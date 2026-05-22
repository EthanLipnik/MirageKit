//
//  StreamPacketSender+FragmentSending.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/10/26.
//
//  Packet fragmentation and transport submission.
//

import CoreMedia
import Foundation
import MirageKit

#if os(macOS)

extension StreamPacketSender {
    /// Fragments an encoded frame, applies optional media encryption, and submits packets to the transport.
    func fragmentAndSendPackets(_ item: WorkItem, accountedBytes: Int) async {
        let fragmentStartTime = CFAbsoluteTimeGetCurrent()

        let maxPayload = maxPayloadSize
        let frameByteCount = max(0, item.frameByteCount)
        let fragmentPlan = Self.fragmentPlan(
            frameByteCount: frameByteCount,
            maxPayload: maxPayload,
            fecBlockSize: item.fecBlockSize
        )
        let dataFragmentCount = fragmentPlan.dataFragmentCount
        let fecBlockSize = max(0, item.fecBlockSize)
        let totalFragments = fragmentPlan.totalFragmentCount
        let timestamp = UInt64(CMTimeGetSeconds(item.presentationTime) * 1_000_000_000)
        var didRecordSendStart = false
        let transportCompletionTracker = TransportCompletionTracker(
            onFinish: { [item, fragmentStartTime, totalFragments] didDrop, error, completedAt in
                Task {
                    await self.completeTransportWorkItem(
                        item: item,
                        startedAt: fragmentStartTime,
                        completedAt: completedAt,
                        totalFragments: totalFragments,
                        didDrop: didDrop,
                        error: error
                    )
                }
            }
        )
        guard Self.canRepresentFragmentPlan(fragmentPlan, frameByteCount: frameByteCount) else {
            dropOversizedFrameDuringFragmentation(
                item: item,
                frameByteCount: frameByteCount,
                totalFragments: totalFragments,
                remainingQueuedBytes: max(0, accountedBytes),
                transportCompletionTracker: transportCompletionTracker
            )
            return
        }

        let context = FragmentSendContext(
            item: item,
            fragmentPlan: fragmentPlan,
            frameByteCount: frameByteCount,
            maxPayload: maxPayload,
            fecBlockSize: fecBlockSize,
            timestamp: timestamp,
            transportCompletionTracker: transportCompletionTracker
        )
        var progress = FragmentSendProgress(remainingQueuedBytes: max(0, accountedBytes))
        var currentSequence = item.sequenceNumberStart
        let interleavedFragmentOrder = if fragmentPlan.parityFragmentCount > 0 {
            Self.fragmentSendOrder(
                dataFragmentCount: dataFragmentCount,
                parityFragmentCount: fragmentPlan.parityFragmentCount,
                fecBlockSize: fecBlockSize
            )
        } else {
            [Int]()
        }
        let sendIterationCount = interleavedFragmentOrder.isEmpty ? totalFragments : interleavedFragmentOrder.count

        for sendIndex in 0 ..< sendIterationCount {
            let fragmentIndex = interleavedFragmentOrder.isEmpty ? sendIndex : interleavedFragmentOrder[sendIndex]
            if item.generation != generation {
                generationAbortDropCount &+= 1
                if progress.submittedFragmentCount > 0, !item.isKeyframe {
                    queueLock.withLock {
                        markDependencyFrameDroppedLocked(item, reason: .generationAbort)
                    }
                }
                MirageLogger
                    .stream("Aborting send for frame \(item.frameNumber) (gen \(item.generation) != \(generation))")
                transportCompletionTracker.recordDrop()
                transportCompletionTracker.close()
                if progress.remainingQueuedBytes > 0 { reduceQueuedBytes(progress.remainingQueuedBytes) }
                return
            }

            let outcome: FragmentSendOutcome = if fragmentIndex < dataFragmentCount {
                await sendDataFragment(
                    fragmentIndex: fragmentIndex,
                    sequenceNumber: currentSequence,
                    context: context,
                    progress: progress
                )
            } else if fragmentPlan.parityFragmentCount > 0 {
                await sendParityFragment(
                    fragmentIndex: fragmentIndex,
                    sequenceNumber: currentSequence,
                    context: context,
                    progress: progress
                )
            } else {
                .skipped
            }

            switch outcome {
            case .skipped:
                break
            case let .submitted(accountedPayloadBytes, sleepSample):
                progress.remainingQueuedBytes = max(0, progress.remainingQueuedBytes - accountedPayloadBytes)
                progress.recordPacingSleep(sleepSample)
                if !didRecordSendStart {
                    recordSendStartDelay(item: item, now: CFAbsoluteTimeGetCurrent())
                    didRecordSendStart = true
                }
                progress.submittedFragmentCount += 1
            case .stopped:
                return
            }
            currentSequence += 1
        }

        if progress.remainingQueuedBytes > 0 { reduceQueuedBytes(progress.remainingQueuedBytes) }
        recordFramePacerSleep(
            totalMs: progress.framePacerSleepTotalMs,
            maxMs: progress.framePacerSleepMaxMs
        )
        transportCompletionTracker.close()
    }

    /// Builds per-fragment flags from frame-level flags and fragment position.
    private func fragmentFlags(index: Int, context: FragmentSendContext) -> FrameFlags {
        var flags = context.item.additionalFlags
        if index > 0, flags.contains(.discontinuity) { flags.remove(.discontinuity) }
        if context.item.isKeyframe { flags.insert(.keyframe) }
        if index == context.fragmentPlan.totalFragmentCount - 1 { flags.insert(.endOfFrame) }
        if context.item.isKeyframe, index == 0 { flags.insert(.parameterSet) }
        return flags
    }

    /// Runs pacing and deadline checks before submitting a fragment.
    private func paceFragmentSend(
        packetBytes: Int,
        context: FragmentSendContext,
        progress: FragmentSendProgress
    ) async -> PacketPacingResult? {
        let item = context.item
        let shouldCheckDeadline = !item.isKeyframe &&
            item.sendDeadline.isFinite &&
            progress.submittedFragmentCount == 0
        let sendDeadline = shouldCheckDeadline ? item.sendDeadline : nil
        if shouldCheckDeadline, isExpiredNonKeyframe(item, now: CFAbsoluteTimeGetCurrent()) {
            dropStaleNonKeyframeDuringFragmentation(
                item: item,
                remainingQueuedBytes: progress.remainingQueuedBytes,
                transportCompletionTracker: context.transportCompletionTracker
            )
            return nil
        }

        let pacingResult = await paceIfNeeded(
            packetBytes: packetBytes,
            isKeyframeBurst: item.isKeyframe,
            totalFragments: context.fragmentPlan.totalFragmentCount,
            targetFrameRate: item.targetFrameRate,
            pacingOverride: item.pacingOverride,
            sendDeadline: sendDeadline
        )
        if pacingResult.didMissDeadline {
            dropStaleNonKeyframeDuringFragmentation(
                item: item,
                remainingQueuedBytes: progress.remainingQueuedBytes,
                transportCompletionTracker: context.transportCompletionTracker
            )
            return nil
        }
        if shouldCheckDeadline, isExpiredNonKeyframe(item, now: CFAbsoluteTimeGetCurrent()) {
            dropStaleNonKeyframeDuringFragmentation(
                item: item,
                remainingQueuedBytes: progress.remainingQueuedBytes,
                transportCompletionTracker: context.transportCompletionTracker
            )
            return nil
        }
        return pacingResult
    }

    /// Builds, optionally encrypts, paces, and submits one data fragment.
    private func sendDataFragment(
        fragmentIndex: Int,
        sequenceNumber: UInt32,
        context: FragmentSendContext,
        progress: FragmentSendProgress
    ) async -> FragmentSendOutcome {
        let item = context.item
        let start = fragmentIndex * context.maxPayload
        let end = min(start + context.maxPayload, context.frameByteCount)
        let fragmentSize = end - start
        guard fragmentSize > 0 else {
            context.transportCompletionTracker.recordDrop()
            return .skipped
        }

        let baseFlags = fragmentFlags(index: fragmentIndex, context: context)
        var payloadFlags = baseFlags
        if mediaSecurityKey != nil { payloadFlags.insert(.encryptedPayload) }
        let checksum: UInt32 = if mediaSecurityKey == nil {
            item.encodedData.withUnsafeBytes { frameBytes in
                CRC32.calculate(UnsafeRawBufferPointer(rebasing: frameBytes[start ..< end]))
            }
        } else {
            0
        }
        let header = FrameHeader(
            flags: payloadFlags,
            streamID: item.streamID,
            sequenceNumber: sequenceNumber,
            timestamp: context.timestamp,
            frameNumber: item.frameNumber,
            fragmentIndex: UInt16(fragmentIndex),
            fragmentCount: UInt16(context.fragmentPlan.totalFragmentCount),
            fecBlockSize: UInt8(clamping: context.fecBlockSize),
            payloadLength: UInt32(fragmentSize),
            frameByteCount: UInt32(context.frameByteCount),
            checksum: checksum,
            contentRect: item.contentRect,
            dimensionToken: item.dimensionToken,
            epoch: item.epoch
        )

        let wirePayload: Data?
        if let mediaSecurityKey {
            do {
                wirePayload = try item.encodedData.withUnsafeBytes { frameBytes in
                    try MirageMediaSecurity.encryptVideoPayload(
                        UnsafeRawBufferPointer(rebasing: frameBytes[start ..< end]),
                        header: header,
                        key: mediaSecurityKey,
                        direction: .hostToClient
                    )
                }
            } catch {
                MirageLogger.error(
                    .stream,
                    "Failed to encrypt video packet for stream \(item.streamID) frame \(item.frameNumber) seq \(sequenceNumber): \(error)"
                )
                context.transportCompletionTracker.recordDrop()
                return .skipped
            }
        } else {
            wirePayload = nil
        }

        let packetPayloadLength = wirePayload?.count ?? fragmentSize
        let packetLength = mirageHeaderSize + packetPayloadLength
        guard let pacingResult = await paceFragmentSend(
            packetBytes: packetLength,
            context: context,
            progress: progress
        ) else {
            return .stopped
        }

        let packetBuffer = packetBufferPool.acquire()
        packetBuffer.prepare(length: packetLength)
        packetBuffer.withMutableBytes { packetBytes in
            guard packetBytes.count >= packetLength,
                  let baseAddress = packetBytes.baseAddress else {
                return
            }
            header.serialize(into: UnsafeMutableRawBufferPointer(
                start: baseAddress,
                count: min(packetBytes.count, mirageHeaderSize)
            ))
            if let wirePayload {
                copyPayload(wirePayload, to: baseAddress)
            } else {
                item.encodedData.withUnsafeBytes { frameBytes in
                    let fragmentBytes = UnsafeRawBufferPointer(rebasing: frameBytes[start ..< end])
                    guard let fragmentBase = fragmentBytes.baseAddress else { return }
                    baseAddress.advanced(by: mirageHeaderSize).copyMemory(
                        from: fragmentBase,
                        byteCount: fragmentSize
                    )
                }
            }
        }

        let packet = packetBuffer.finalize(length: packetLength)
        let duplicatePacket: Data? = if Self.shouldDuplicateParameterSetPacket(
            isExperimentEnabled: awdlExperimentEnabled,
            isKeyframe: item.isKeyframe,
            fragmentIndex: fragmentIndex,
            flags: baseFlags
        ) {
            Data(packet)
        } else {
            nil
        }

        context.transportCompletionTracker.registerSubmission()
        sendPacket(packet) { error in
            packetBuffer.release()
            self.reduceQueuedBytes(fragmentSize)
            context.transportCompletionTracker.finishSubmission(error: error)
        }
        if let duplicatePacket {
            context.transportCompletionTracker.registerSubmission()
            sendPacket(duplicatePacket) { error in
                context.transportCompletionTracker.finishSubmission(error: error)
            }
        }
        return .submitted(accountedPayloadBytes: fragmentSize, sleepSample: pacingResult.sleepSample)
    }

    /// Builds, optionally encrypts, paces, and submits one FEC parity fragment.
    private func sendParityFragment(
        fragmentIndex: Int,
        sequenceNumber: UInt32,
        context: FragmentSendContext,
        progress: FragmentSendProgress
    ) async -> FragmentSendOutcome {
        let item = context.item
        let parityIndex = fragmentIndex - context.fragmentPlan.dataFragmentCount
        guard context.fecBlockSize > 0 else {
            context.transportCompletionTracker.recordDrop()
            return .skipped
        }
        let blockStart = parityIndex * context.fecBlockSize
        let blockEnd = min(blockStart + context.fecBlockSize, context.fragmentPlan.dataFragmentCount)
        guard blockStart < blockEnd else {
            context.transportCompletionTracker.recordDrop()
            return .skipped
        }

        let parityLength = parityPayloadLength(
            frameByteCount: context.frameByteCount,
            blockStart: blockStart,
            maxPayload: context.maxPayload
        )
        let parityData = computeParity(
            encodedData: item.encodedData,
            frameByteCount: context.frameByteCount,
            blockStart: blockStart,
            blockEnd: blockEnd,
            payloadLength: parityLength,
            maxPayload: context.maxPayload
        )
        guard !parityData.isEmpty else {
            context.transportCompletionTracker.recordDrop()
            return .skipped
        }

        var parityFlags = fragmentFlags(index: fragmentIndex, context: context)
        parityFlags.insert(.fecParity)
        if mediaSecurityKey != nil { parityFlags.insert(.encryptedPayload) }
        let checksum: UInt32 = mediaSecurityKey == nil ? CRC32.calculate(parityData) : 0
        let header = FrameHeader(
            flags: parityFlags,
            streamID: item.streamID,
            sequenceNumber: sequenceNumber,
            timestamp: context.timestamp,
            frameNumber: item.frameNumber,
            fragmentIndex: UInt16(fragmentIndex),
            fragmentCount: UInt16(context.fragmentPlan.totalFragmentCount),
            fecBlockSize: UInt8(clamping: context.fecBlockSize),
            payloadLength: UInt32(parityData.count),
            frameByteCount: UInt32(context.frameByteCount),
            checksum: checksum,
            contentRect: item.contentRect,
            dimensionToken: item.dimensionToken,
            epoch: item.epoch
        )

        let wirePayload: Data
        if let mediaSecurityKey {
            do {
                wirePayload = try parityData.withUnsafeBytes { parityBytes in
                    try MirageMediaSecurity.encryptVideoPayload(
                        parityBytes,
                        header: header,
                        key: mediaSecurityKey,
                        direction: .hostToClient
                    )
                }
            } catch {
                MirageLogger.error(
                    .stream,
                    "Failed to encrypt parity packet for stream \(item.streamID) frame \(item.frameNumber) seq \(sequenceNumber): \(error)"
                )
                context.transportCompletionTracker.recordDrop()
                return .skipped
            }
        } else {
            wirePayload = parityData
        }

        let packetLength = mirageHeaderSize + wirePayload.count
        guard let pacingResult = await paceFragmentSend(
            packetBytes: packetLength,
            context: context,
            progress: progress
        ) else {
            return .stopped
        }

        let packetBuffer = packetBufferPool.acquire()
        packetBuffer.prepare(length: packetLength)
        packetBuffer.withMutableBytes { packetBytes in
            guard packetBytes.count >= packetLength,
                  let baseAddress = packetBytes.baseAddress else {
                return
            }
            header.serialize(into: UnsafeMutableRawBufferPointer(
                start: baseAddress,
                count: min(packetBytes.count, mirageHeaderSize)
            ))
            copyPayload(wirePayload, to: baseAddress)
        }

        let packet = packetBuffer.finalize(length: packetLength)
        let accountedPayloadBytes = context.maxPayload
        context.transportCompletionTracker.registerSubmission()
        sendPacket(packet) { error in
            packetBuffer.release()
            self.reduceQueuedBytes(accountedPayloadBytes)
            context.transportCompletionTracker.finishSubmission(error: error)
        }
        return .submitted(accountedPayloadBytes: accountedPayloadBytes, sleepSample: pacingResult.sleepSample)
    }

    /// Copies packet payload bytes immediately after the fixed Mirage frame header.
    private nonisolated func copyPayload(_ payload: Data, to baseAddress: UnsafeMutableRawPointer) {
        payload.withUnsafeBytes { payloadBytes in
            guard let payloadBase = payloadBytes.baseAddress else { return }
            baseAddress.advanced(by: mirageHeaderSize).copyMemory(
                from: payloadBase,
                byteCount: payload.count
            )
        }
    }
}

#endif
