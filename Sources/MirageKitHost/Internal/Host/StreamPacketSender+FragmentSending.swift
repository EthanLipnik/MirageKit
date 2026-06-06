//
//  StreamPacketSender+FragmentSending.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/10/26.
//
//  Packet fragmentation and transport submission.
//

import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageKit
import MirageKitClientPresentation
import MirageMedia
import MirageWire
import CoreMedia
import Foundation

#if os(macOS)

extension StreamPacketSender {
    /// Fragments an encoded frame, applies optional media encryption, and submits packets to the transport.
    func fragmentAndSendPackets(_ item: WorkItem, accountedBytes: Int) async {
        let fragmentStartTime = CFAbsoluteTimeGetCurrent()

        let usesMosaicMediaUnitHeader = usesMosaicMediaUnitHeader(for: item)
        let maxPayload = maximumPayloadSize(usesMosaicMediaUnitHeader: usesMosaicMediaUnitHeader)
        let frameByteCount = max(0, item.frameByteCount)
        let effectiveFECBlockSize = usesMosaicMediaUnitHeader ? 0 : item.fecBlockSize
        let fragmentPlan = Self.fragmentPlan(
            frameByteCount: frameByteCount,
            maxPayload: maxPayload,
            fecBlockSize: effectiveFECBlockSize
        )
        let dataFragmentCount = fragmentPlan.dataFragmentCount
        let fecBlockSize = max(0, effectiveFECBlockSize)
        let totalFragments = fragmentPlan.totalFragmentCount
        let timestamp = UInt64(CMTimeGetSeconds(item.presentationTime) * 1_000_000_000)
        var didRecordSendStart = false
        let transportCompletionTracker = TransportCompletionTracker(
            onFinish: { [item, fragmentStartTime, totalFragments] didDrop, error, queuedUnreliableDrops, completedAt in
                Task {
                    await self.completeTransportWorkItem(
                        item: item,
                        startedAt: fragmentStartTime,
                        completedAt: completedAt,
                        totalFragments: totalFragments,
                        didDrop: didDrop,
                        queuedUnreliableDrops: queuedUnreliableDrops,
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
                        markDependencyFrameDroppedLocked(
                            item,
                            reason: .generationAbort
                        )
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
    private func fragmentFlags(index: Int, context: FragmentSendContext) -> MirageWire.FrameFlags {
        var flags = context.item.additionalFlags
        if index > 0, flags.contains(.discontinuity) { flags.remove(.discontinuity) }
        if context.item.isKeyframe { flags.insert(.keyframe) }
        if index == context.fragmentPlan.totalFragmentCount - 1 { flags.insert(.endOfFrame) }
        if context.item.isKeyframe, index == 0 { flags.insert(.parameterSet) }
        return flags
    }

    private func mosaicFragmentFlags(index: Int, context: FragmentSendContext) -> MirageWire.MirageMosaicPacketFlags {
        let frameFlags = fragmentFlags(index: index, context: context)
        var flags = MirageWire.MirageMosaicPacketFlags.atomicGroup
        if frameFlags.contains(.keyframe) { flags.insert(.keyframe) }
        if frameFlags.contains(.endOfFrame) { flags.insert(.endOfUnit) }
        if frameFlags.contains(.parameterSet) { flags.insert(.parameterSet) }
        if frameFlags.contains(.discontinuity) { flags.insert(.discontinuity) }
        if frameFlags.contains(.priority) { flags.insert(.priority) }
        return flags
    }

    private nonisolated func usesMosaicMediaUnitHeader(for item: WorkItem) -> Bool {
        item.additionalFlags.contains(.desktopStream)
    }

    private nonisolated func maximumPayloadSize(usesMosaicMediaUnitHeader: Bool) -> Int {
        guard usesMosaicMediaUnitHeader else { return maxPayloadSize }
        let headerOverheadDelta = max(0, MirageWire.mirageMosaicHeaderSize - MirageWire.mirageHeaderSize)
        return max(1, maxPayloadSize - headerOverheadDelta)
    }

    /// Runs pacing before submitting a fragment.
    private func paceFragmentSend(
        packetBytes: Int,
        context: FragmentSendContext,
        progress: FragmentSendProgress
    ) async -> PacketPacingResult? {
        let item = context.item
        let pacingResult = await paceIfNeeded(
            packetBytes: packetBytes,
            isKeyframeBurst: item.isKeyframe,
            totalFragments: context.fragmentPlan.totalFragmentCount,
            targetFrameRate: item.targetFrameRate,
            pacingOverride: item.pacingOverride
        )
        return pacingResult
    }

    /// Builds, optionally encrypts, paces, and submits one data fragment.
    private func sendDataFragment(
        fragmentIndex: Int,
        sequenceNumber: UInt32,
        context: FragmentSendContext,
        progress: FragmentSendProgress
    ) async -> FragmentSendOutcome {
        if usesMosaicMediaUnitHeader(for: context.item) {
            return await sendMosaicDataFragment(
                fragmentIndex: fragmentIndex,
                sequenceNumber: sequenceNumber,
                context: context,
                progress: progress
            )
        }

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
                MirageWire.CRC32.calculate(UnsafeRawBufferPointer(rebasing: frameBytes[start ..< end]))
            }
        } else {
            0
        }
        let header = MirageWire.FrameHeader(
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
        let packetLength = MirageWire.mirageHeaderSize + packetPayloadLength
        guard let pacingResult = await paceFragmentSend(
            packetBytes: packetLength,
            context: context,
            progress: progress
        ) else {
            return .stopped
        }
        var combinedPacingSample = pacingResult.sleepSample

        let packetBuffer = packetBufferPool.acquire()
        packetBuffer.prepare(length: packetLength)
        packetBuffer.withMutableBytes { packetBytes in
            guard packetBytes.count >= packetLength,
                  let baseAddress = packetBytes.baseAddress else {
                return
            }
            header.serialize(into: UnsafeMutableRawBufferPointer(
                start: baseAddress,
                count: min(packetBytes.count, MirageWire.mirageHeaderSize)
            ))
            if let wirePayload {
                copyPayload(wirePayload, to: baseAddress)
            } else {
                item.encodedData.withUnsafeBytes { frameBytes in
                    let fragmentBytes = UnsafeRawBufferPointer(rebasing: frameBytes[start ..< end])
                    guard let fragmentBase = fragmentBytes.baseAddress else { return }
                    baseAddress.advanced(by: MirageWire.mirageHeaderSize).copyMemory(
                        from: fragmentBase,
                        byteCount: fragmentSize
                    )
                }
            }
        }

        let packet = packetBuffer.finalize(length: packetLength)
        let duplicatePacket: Data? = if Self.shouldDuplicateParameterSetPacket(
            isEnabled: duplicatesParameterSetPackets,
            isKeyframe: item.isKeyframe,
            fragmentIndex: fragmentIndex,
            flags: baseFlags
        ) {
            Data(packet)
        } else {
            nil
        }

        await sendTransportPacket(
            packet,
            packetBuffer: packetBuffer,
            accountedPayloadBytes: fragmentSize,
            metadata: transportMetadata(
                item: item,
                fragmentIndex: fragmentIndex,
                fragmentCount: context.fragmentPlan.totalFragmentCount,
                isParity: false
            ),
            context: context
        )
        if let duplicatePacket {
            guard let duplicatePacingResult = await paceFragmentSend(
                packetBytes: duplicatePacket.count,
                context: context,
                progress: progress
            ) else {
                return .stopped
            }
            combinedPacingSample = PacketPacingSleepSample(
                totalMs: combinedPacingSample.totalMs + duplicatePacingResult.sleepSample.totalMs,
                maxMs: max(combinedPacingSample.maxMs, duplicatePacingResult.sleepSample.maxMs)
            )
            sendUnreliableDuplicatePacket(
                duplicatePacket,
                metadata: transportMetadata(
                    item: item,
                    fragmentIndex: fragmentIndex,
                    fragmentCount: context.fragmentPlan.totalFragmentCount,
                    isParity: false
                ),
                context: context
            )
        }
        return .submitted(accountedPayloadBytes: fragmentSize, sleepSample: combinedPacingSample)
    }

    /// Builds, optionally encrypts, paces, and submits one Mosaic media-unit data fragment.
    private func sendMosaicDataFragment(
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

        var payloadFlags = mosaicFragmentFlags(index: fragmentIndex, context: context)
        if mediaSecurityKey != nil { payloadFlags.insert(.encryptedPayload) }
        let checksum: UInt32 = mediaSecurityKey == nil ? item.encodedData.withUnsafeBytes { frameBytes in
            MirageWire.CRC32.calculate(UnsafeRawBufferPointer(rebasing: frameBytes[start ..< end]))
        } : 0
        let mosaicMetadata = item.mosaicMediaUnitMetadata
        let header = MirageWire.MirageMosaicPacketHeader(
            flags: payloadFlags,
            streamID: item.streamID,
            packetSequence: sequenceNumber,
            timestamp: context.timestamp,
            tilePlanEpoch: mosaicMetadata?.tilePlanEpoch ?? UInt32(item.epoch),
            mediaEpoch: mosaicMetadata?.mediaEpoch ?? UInt32(item.dimensionToken),
            mediaUnitIndex: mosaicMetadata?.mediaUnitIndex ?? 0,
            tileIndex: mosaicMetadata?.tileIndex ?? 0,
            transportGroupIndex: mosaicMetadata?.transportGroupIndex ?? 0,
            presentationGroupIndex: mosaicMetadata?.presentationGroupIndex ?? 0,
            unitFrameNumber: item.frameNumber,
            tileVersion: mosaicMetadata?.tileVersion ?? item.frameNumber,
            dependencyVersion: mosaicMetadata?.dependencyVersion ??
                (item.isKeyframe ? item.frameNumber : latestKeyframeFrameNumber),
            fragmentIndex: UInt16(fragmentIndex),
            fragmentCount: UInt16(context.fragmentPlan.totalFragmentCount),
            fecBlockSize: 0,
            payloadLength: UInt32(fragmentSize),
            unitByteCount: UInt32(context.frameByteCount),
            checksum: checksum
        )

        let wirePayload: Data?
        if let mediaSecurityKey {
            do {
                wirePayload = try item.encodedData.withUnsafeBytes { frameBytes in
                    try MirageMediaSecurity.encryptMosaicVideoPayload(
                        UnsafeRawBufferPointer(rebasing: frameBytes[start ..< end]),
                        header: header,
                        key: mediaSecurityKey,
                        direction: .hostToClient
                    )
                }
            } catch {
                MirageLogger.error(
                    .stream,
                    "Failed to encrypt Mosaic video packet for stream \(item.streamID) frame \(item.frameNumber) seq \(sequenceNumber): \(error)"
                )
                context.transportCompletionTracker.recordDrop()
                return .skipped
            }
        } else {
            wirePayload = nil
        }

        let packetPayloadLength = wirePayload?.count ?? fragmentSize
        let packetLength = MirageWire.mirageMosaicHeaderSize + packetPayloadLength
        guard let pacingResult = await paceFragmentSend(
            packetBytes: packetLength,
            context: context,
            progress: progress
        ) else {
            return .stopped
        }
        var combinedPacingSample = pacingResult.sleepSample

        let packetBuffer = packetBufferPool.acquire()
        packetBuffer.prepare(length: packetLength)
        packetBuffer.withMutableBytes { packetBytes in
            guard packetBytes.count >= packetLength,
                  let baseAddress = packetBytes.baseAddress else {
                return
            }
            let serializedHeader = header.serialize()
            serializedHeader.withUnsafeBytes { headerBytes in
                guard let headerBase = headerBytes.baseAddress else { return }
                baseAddress.copyMemory(from: headerBase, byteCount: serializedHeader.count)
            }
            if let wirePayload {
                copyPayload(wirePayload, to: baseAddress, headerSize: MirageWire.mirageMosaicHeaderSize)
            } else {
                item.encodedData.withUnsafeBytes { frameBytes in
                    let fragmentBytes = UnsafeRawBufferPointer(rebasing: frameBytes[start ..< end])
                    guard let fragmentBase = fragmentBytes.baseAddress else { return }
                    baseAddress.advanced(by: MirageWire.mirageMosaicHeaderSize).copyMemory(
                        from: fragmentBase,
                        byteCount: fragmentSize
                    )
                }
            }
        }

        let packet = packetBuffer.finalize(length: packetLength)
        let duplicatePacket: Data? = if Self.shouldDuplicateParameterSetPacket(
            isEnabled: duplicatesParameterSetPackets,
            isKeyframe: item.isKeyframe,
            fragmentIndex: fragmentIndex,
            flags: fragmentFlags(index: fragmentIndex, context: context)
        ) {
            Data(packet)
        } else {
            nil
        }

        await sendTransportPacket(
            packet,
            packetBuffer: packetBuffer,
            accountedPayloadBytes: fragmentSize,
            metadata: transportMetadata(
                item: item,
                fragmentIndex: fragmentIndex,
                fragmentCount: context.fragmentPlan.totalFragmentCount,
                isParity: false
            ),
            context: context
        )
        if let duplicatePacket {
            guard let duplicatePacingResult = await paceFragmentSend(
                packetBytes: duplicatePacket.count,
                context: context,
                progress: progress
            ) else {
                return .stopped
            }
            combinedPacingSample = PacketPacingSleepSample(
                totalMs: combinedPacingSample.totalMs + duplicatePacingResult.sleepSample.totalMs,
                maxMs: max(combinedPacingSample.maxMs, duplicatePacingResult.sleepSample.maxMs)
            )
            sendUnreliableDuplicatePacket(
                duplicatePacket,
                metadata: transportMetadata(
                    item: item,
                    fragmentIndex: fragmentIndex,
                    fragmentCount: context.fragmentPlan.totalFragmentCount,
                    isParity: false
                ),
                context: context
            )
        }
        return .submitted(accountedPayloadBytes: fragmentSize, sleepSample: combinedPacingSample)
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
        let checksum: UInt32 = mediaSecurityKey == nil ? MirageWire.CRC32.calculate(parityData) : 0
        let header = MirageWire.FrameHeader(
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

        let packetLength = MirageWire.mirageHeaderSize + wirePayload.count
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
                count: min(packetBytes.count, MirageWire.mirageHeaderSize)
            ))
            copyPayload(wirePayload, to: baseAddress)
        }

        let packet = packetBuffer.finalize(length: packetLength)
        let accountedPayloadBytes = context.maxPayload
        await sendTransportPacket(
            packet,
            packetBuffer: packetBuffer,
            accountedPayloadBytes: accountedPayloadBytes,
            metadata: transportMetadata(
                item: item,
                fragmentIndex: fragmentIndex,
                fragmentCount: context.fragmentPlan.totalFragmentCount,
                isParity: true
            ),
            context: context
        )
        return .submitted(accountedPayloadBytes: accountedPayloadBytes, sleepSample: pacingResult.sleepSample)
    }

    /// Submits one transport packet using the selected video delivery contract.
    private func sendTransportPacket(
        _ packet: Data,
        packetBuffer: PacketBufferPool.Buffer,
        accountedPayloadBytes: Int,
        metadata: TransportPacketMetadata,
        context: FragmentSendContext
    ) async {
        context.transportCompletionTracker.registerSubmission()
        sendPacket(packet, metadata) { error in
            packetBuffer.release()
            self.reduceQueuedBytes(accountedPayloadBytes)
            if let drop = MirageQueuedUnreliableSendDrop(error: error) {
                self.logQueuedUnreliableTransportDrop(
                    drop,
                    metadata: metadata,
                    accountedPayloadBytes: accountedPayloadBytes
                )
                if !metadata.isKeyframe, !metadata.isParity {
                    self.queueLock.withLock {
                        self.markDependencyFrameDroppedLocked(
                            context.item,
                            reason: .transportDrop
                        )
                    }
                }
                context.transportCompletionTracker.finishDroppedSubmission(
                    drop,
                    countsAsFrameDrop: !metadata.isParity
                )
            } else {
                context.transportCompletionTracker.finishSubmission(error: error)
            }
        }
    }

    /// Parameter-set duplication is only valid on the unreliable packet lane.
    private func sendUnreliableDuplicatePacket(
        _ packet: Data,
        metadata: TransportPacketMetadata,
        context: FragmentSendContext
    ) {
        context.transportCompletionTracker.registerSubmission()
        sendPacket(packet, metadata) { error in
            if let drop = MirageQueuedUnreliableSendDrop(error: error) {
                self.logQueuedUnreliableTransportDrop(
                    drop,
                    metadata: metadata,
                    accountedPayloadBytes: packet.count
                )
                context.transportCompletionTracker.finishDroppedSubmission(drop, countsAsFrameDrop: false)
            } else {
                context.transportCompletionTracker.finishSubmission(error: error)
            }
        }
    }

    private func transportMetadata(
        item: WorkItem,
        fragmentIndex: Int,
        fragmentCount: Int,
        isParity: Bool
    ) -> TransportPacketMetadata {
        TransportPacketMetadata(
            streamID: item.streamID,
            frameNumber: item.frameNumber,
            fragmentIndex: fragmentIndex,
            fragmentCount: fragmentCount,
            isKeyframe: item.isKeyframe,
            isParity: isParity,
            isRecovery: !item.isKeyframe &&
                !isParity &&
                !usesMosaicMediaUnitHeader(for: item) &&
                item.fecBlockSize > 1,
            sendDeadline: transportSendDeadline(for: item)
        )
    }

    private func transportSendDeadline(for item: WorkItem) -> CFAbsoluteTime {
        guard item.usesAwdlRealtimeQueuePolicy else {
            return item.sendDeadline
        }
        return hardSendDeadline(for: item)
    }

    private nonisolated func logQueuedUnreliableTransportDrop(
        _ drop: MirageQueuedUnreliableSendDrop,
        metadata: TransportPacketMetadata,
        accountedPayloadBytes: Int
    ) {
        let now = CFAbsoluteTimeGetCurrent()
        let deadlineRemainingMs = Int(max(0, (metadata.sendDeadline - now) * 1000).rounded())
        let profile = drop.profile?.rawValue ?? "nil"
        let frameID = drop.frameID.map(String.init) ?? "nil"
        let loomFragmentIndex = drop.fragmentIndex.map(String.init) ?? "nil"
        let loomFragmentCount = drop.fragmentCount.map(String.init) ?? "nil"
        MirageLogger.stream(
            "event=queued_unreliable_transport_drop stream=\(metadata.streamID) " +
                "frame=\(metadata.frameNumber) fragment=\(metadata.fragmentIndex)/\(metadata.fragmentCount) " +
                "keyframe=\(metadata.isKeyframe) parity=\(metadata.isParity) recovery=\(metadata.isRecovery) " +
                "loomReason=\(drop.reason.rawValue) profile=\(profile) frameID=\(frameID) " +
                "loomFragment=\(loomFragmentIndex)/\(loomFragmentCount) " +
                "deadlineRemainingMs=\(deadlineRemainingMs) accountedPayloadBytes=\(accountedPayloadBytes) " +
                "queuedBytes=\(queuedByteCount)"
        )
    }

    /// Copies packet payload bytes immediately after the fixed Mirage frame header.
    private nonisolated func copyPayload(_ payload: Data, to baseAddress: UnsafeMutableRawPointer) {
        copyPayload(payload, to: baseAddress, headerSize: MirageWire.mirageHeaderSize)
    }

    /// Copies packet payload bytes immediately after the selected Mirage media header.
    private nonisolated func copyPayload(
        _ payload: Data,
        to baseAddress: UnsafeMutableRawPointer,
        headerSize: Int
    ) {
        payload.withUnsafeBytes { payloadBytes in
            guard let payloadBase = payloadBytes.baseAddress else { return }
            baseAddress.advanced(by: headerSize).copyMemory(
                from: payloadBase,
                byteCount: payload.count
            )
        }
    }
}

#endif
