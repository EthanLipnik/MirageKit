//
//  FrameReassembler+FEC.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/9/26.
//
//  Forward-error-correction helpers for fragmented video frames.
//

import Foundation
import MirageKit

extension FrameReassembler {
    nonisolated static let hardSingleFrameCompressedByteCap = 64 * 1024 * 1024

    struct FrameAssemblyPlan: Sendable, Equatable {
        let frameByteCount: Int
        let dataFragmentCount: Int
        let bufferCapacity: Int
    }

    func resolvedFrameByteCount(header: FrameHeader, maxPayloadSize: Int) -> Int {
        let byteCount = Int(header.frameByteCount)
        if byteCount > 0 { return byteCount }
        let fragments = Int(header.fragmentCount)
        return max(0, fragments * maxPayloadSize)
    }

    func resolvedDataFragmentCount(
        header: FrameHeader,
        frameByteCount: Int,
        maxPayloadSize: Int
    )
    -> Int {
        guard maxPayloadSize > 0 else { return Int(header.fragmentCount) }
        if frameByteCount > 0 { return (frameByteCount + maxPayloadSize - 1) / maxPayloadSize }
        return Int(header.fragmentCount)
    }

    func validatedFrameAssemblyPlan(header: FrameHeader) -> FrameAssemblyPlan? {
        let totalFragmentCount = Int(header.fragmentCount)
        let fragmentIndex = Int(header.fragmentIndex)
        guard maxPayloadSize > 0,
              totalFragmentCount > 0,
              fragmentIndex >= 0,
              fragmentIndex < totalFragmentCount else {
            return nil
        }

        let frameByteCount = resolvedFrameByteCount(header: header, maxPayloadSize: maxPayloadSize)
        let dataFragmentCount = resolvedDataFragmentCount(
            header: header,
            frameByteCount: frameByteCount,
            maxPayloadSize: maxPayloadSize
        )
        guard frameByteCount > 0,
              dataFragmentCount > 0,
              dataFragmentCount <= totalFragmentCount else {
            return nil
        }

        let singleFrameCap = min(memoryBudget.maxPendingBytes, Self.hardSingleFrameCompressedByteCap)
        guard frameByteCount <= singleFrameCap else { return nil }

        let capacityResult = max(1, dataFragmentCount).multipliedReportingOverflow(by: maxPayloadSize)
        guard !capacityResult.overflow else { return nil }
        let capacity = capacityResult.partialValue
        guard capacity > 0, capacity <= singleFrameCap else { return nil }

        return FrameAssemblyPlan(
            frameByteCount: frameByteCount,
            dataFragmentCount: dataFragmentCount,
            bufferCapacity: capacity
        )
    }

    func parityIndexForDataFragment(fragmentIndex: Int, frame: PendingFrame) -> Int? {
        let parityCount = Int(frame.totalFragments) - frame.dataFragmentCount
        guard parityCount > 0 else { return nil }
        let blockSize = frame.fecBlockSize
        guard blockSize > 1 else { return nil }
        let blockIndex = fragmentIndex / blockSize
        guard blockIndex < parityCount else { return nil }
        return blockIndex
    }

    func payloadLength(
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

    func tryRecoverMissingFragment(
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
        fecRecoveredFragmentCount += 1
        if frame.isKeyframe || recoverIndex != 0 || parityIndex != 0 {
            MirageLogger.log(.frameAssembly, "Recovered fragment \(recoverIndex) via FEC (block \(parityIndex))")
        }
    }
}
