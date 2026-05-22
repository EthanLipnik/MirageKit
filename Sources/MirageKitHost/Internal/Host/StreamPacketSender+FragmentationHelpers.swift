//
//  StreamPacketSender+FragmentationHelpers.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/9/26.
//

import Foundation
import MirageKit

#if os(macOS)

extension StreamPacketSender {
    /// Finalizes telemetry, error callbacks, and keyframe logging after frame transport completes.
    func completeTransportWorkItem(
        item: WorkItem,
        startedAt: CFAbsoluteTime,
        completedAt: CFAbsoluteTime,
        totalFragments: Int,
        didDrop: Bool,
        error: (any Error)?
    ) {
        if let error {
            onSendError?(error)
        } else if !didDrop {
            recordSendCompletion(item: item, completedAt: completedAt)
        }

        if item.isKeyframe {
            if error == nil, !didDrop {
                let fragmentDurationMs = (completedAt - startedAt) * 1000
                let roundedDuration = (fragmentDurationMs * 100).rounded() / 100
                let bytesKB = Double(item.encodedData.count) / 1024.0
                let roundedBytes = (bytesKB * 10).rounded() / 10
                MirageLogger
                    .timing(
                        "\(item.logPrefix) \(item.frameNumber) keyframe: \(roundedDuration)ms, \(totalFragments) packets, \(roundedBytes)KB"
                    )
            }
        }
    }

    /// Returns the payload length covered by one FEC parity block.
    func parityPayloadLength(frameByteCount: Int, blockStart: Int, maxPayload: Int) -> Int {
        guard frameByteCount > 0, maxPayload > 0 else { return 0 }
        let start = blockStart * maxPayload
        let remaining = max(0, frameByteCount - start)
        return min(maxPayload, remaining)
    }

    /// Drops a non-keyframe that expired while fragmentation or pacing was in progress.
    func dropStaleNonKeyframeDuringFragmentation(
        item: WorkItem,
        remainingQueuedBytes: Int,
        transportCompletionTracker: TransportCompletionTracker
    ) {
        stalePacketDropCount &+= 1
        queueLock.withLock {
            markDependencyFrameDroppedLocked(
                item,
                reason: .expiredDuringSend
            )
        }
        transportCompletionTracker.recordDrop()
        transportCompletionTracker.close()
        if remainingQueuedBytes > 0 { reduceQueuedBytes(remainingQueuedBytes) }
    }

    /// Drops a frame whose fragment counts cannot be represented on the wire.
    func dropOversizedFrameDuringFragmentation(
        item: WorkItem,
        frameByteCount: Int,
        totalFragments: Int,
        remainingQueuedBytes: Int,
        transportCompletionTracker: TransportCompletionTracker
    ) {
        stalePacketDropCount &+= 1
        queueLock.withLock {
            markDependencyFrameDroppedLocked(
                item,
                reason: .oversizedFrame
            )
        }
        MirageLogger.stream(
            "Dropping oversized encoded frame \(item.frameNumber) for stream \(item.streamID): " +
                "frameBytes=\(frameByteCount), fragments=\(totalFragments), " +
                "maxFrameBytes=\(UInt32.max), maxFragments=\(UInt16.max)"
        )
        transportCompletionTracker.recordDrop()
        transportCompletionTracker.close()
        if remainingQueuedBytes > 0 { reduceQueuedBytes(remainingQueuedBytes) }
    }

    /// Computes XOR parity across data fragments in one FEC block.
    func computeParity(
        encodedData: Data,
        frameByteCount: Int,
        blockStart: Int,
        blockEnd: Int,
        payloadLength: Int,
        maxPayload: Int
    )
    -> Data {
        guard payloadLength > 0 else { return Data() }
        var parity = Data(repeating: 0, count: payloadLength)
        parity.withUnsafeMutableBytes { parityBytes in
            let parityPtr = parityBytes.bindMemory(to: UInt8.self)
            guard let parityBase = parityPtr.baseAddress else { return }
            encodedData.withUnsafeBytes { dataBytes in
                let dataPtr = dataBytes.bindMemory(to: UInt8.self)
                guard let dataBase = dataPtr.baseAddress else { return }
                for fragmentIndex in blockStart ..< blockEnd {
                    let start = fragmentIndex * maxPayload
                    let remaining = max(0, frameByteCount - start)
                    let fragmentSize = min(maxPayload, remaining)
                    guard fragmentSize > 0 else { continue }
                    let sourcePtr = dataBase.advanced(by: start)
                    let bytesToXor = min(fragmentSize, payloadLength)
                    let src = sourcePtr
                    for i in 0 ..< bytesToXor {
                        parityBase[i] ^= src[i]
                    }
                }
            }
        }
        return parity
    }
}

#endif
