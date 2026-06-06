//
//  MirageQualityTestTransfer+Loom.swift
//  MirageConnectivity
//
//  Created by Ethan Lipnik on 6/3/26.
//
//  Generated object-transfer support for connection quality tests.
//

import Foundation
import Loom

package enum MirageQualityTestTransfer {
    package static let byteCount: UInt64 = 100_000_000
    package static let stageID = 0
    package static let logicalName = "mirage-connection-test-noise.bin"
    package static let transferKind = "connection-test-noise"
    package static let metadataKindKey = "mirage.transfer-kind"
    package static let metadataTestIDKey = "mirage.test-id"

    package static func metadata(testID: UUID) -> [String: String] {
        [
            metadataKindKey: transferKind,
            metadataTestIDKey: testID.uuidString.lowercased(),
        ]
    }

    package static func isMatchingTransfer(
        offer: MirageTransferOffer,
        testID: UUID
    ) -> Bool {
        offer.metadata[metadataKindKey] == transferKind &&
            offer.metadata[metadataTestIDKey] == testID.uuidString.lowercased()
    }
}

package struct MirageQualityTestNoiseSource: LoomTransferSource {
    package let byteLength: UInt64

    package init(byteLength: UInt64 = MirageQualityTestTransfer.byteCount) {
        self.byteLength = byteLength
    }

    package func read(offset: UInt64, maxLength: Int) async throws -> Data {
        guard maxLength > 0, offset < byteLength else { return Data() }

        let count = Int(min(UInt64(maxLength), byteLength - offset))
        let pattern = Self.noisePattern
        return pattern.withUnsafeBufferPointer { patternBuffer in
            guard let patternBaseAddress = patternBuffer.baseAddress else { return Data() }
            var bytes = [UInt8](repeating: 0, count: count)
            bytes.withUnsafeMutableBufferPointer { destinationBuffer in
                guard let destinationBaseAddress = destinationBuffer.baseAddress else { return }
                var copied = 0
                while copied < count {
                    let patternOffset = Int(
                        (offset + UInt64(copied)) % UInt64(pattern.count)
                    )
                    let copyCount = min(count - copied, pattern.count - patternOffset)
                    destinationBaseAddress
                        .advanced(by: copied)
                        .update(
                            from: patternBaseAddress.advanced(by: patternOffset),
                            count: copyCount
                        )
                    copied += copyCount
                }
            }
            return Data(bytes)
        }
    }

    private static let noisePattern: [UInt8] = makeNoisePattern(byteCount: 1024 * 1024)

    private static func makeNoisePattern(byteCount: Int) -> [UInt8] {
        var seed: UInt64 = 0x9e37_79b9_7f4a_7c15
        var bytes = [UInt8](repeating: 0, count: max(0, byteCount))
        var word: UInt64 = 0
        var remainingWordBytes = 0

        for index in bytes.indices {
            if remainingWordBytes == 0 {
                seed = nextNoiseWord(seed)
                word = seed
                remainingWordBytes = MemoryLayout<UInt64>.size
            }
            bytes[index] = UInt8(truncatingIfNeeded: word)
            word >>= 8
            remainingWordBytes -= 1
        }

        return bytes
    }

    private static func nextNoiseWord(_ value: UInt64) -> UInt64 {
        var z = value &+ 0x9e37_79b9_7f4a_7c15
        z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
        z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
        return z ^ (z >> 31)
    }
}

package actor MirageQualityTestDiscardSink: LoomTransferSink {
    package struct Metrics: Equatable, Sendable {
        package let bytesWritten: UInt64
        package let startedAtTimestampNs: UInt64
        package let completedAtTimestampNs: UInt64

        package var durationMs: Int {
            max(1, Int((completedAtTimestampNs &- startedAtTimestampNs) / 1_000_000))
        }
    }

    private var bytesWritten: UInt64 = 0
    private var firstWriteTime: CFAbsoluteTime?
    private var lastWriteTime: CFAbsoluteTime?

    package init() {}

    package func truncate(to byteCount: UInt64) async throws {
        bytesWritten = byteCount
        firstWriteTime = nil
        lastWriteTime = nil
    }

    package func write(_ data: Data, at offset: UInt64) async throws {
        let now = CFAbsoluteTimeGetCurrent()
        if firstWriteTime == nil {
            firstWriteTime = now
        }
        lastWriteTime = now
        bytesWritten = max(bytesWritten, offset + UInt64(data.count))
    }

    package func finalize(offer _: LoomTransferOffer, bytesWritten: UInt64) async throws {
        finish(bytesWritten: bytesWritten)
    }

    package func finalize(offer _: MirageTransferOffer, bytesWritten: UInt64) async throws {
        finish(bytesWritten: bytesWritten)
    }

    private func finish(bytesWritten: UInt64) {
        let now = CFAbsoluteTimeGetCurrent()
        if firstWriteTime == nil {
            firstWriteTime = now
        }
        if lastWriteTime == nil {
            lastWriteTime = now
        }
        self.bytesWritten = bytesWritten
    }

    package func metrics() -> Metrics {
        let now = CFAbsoluteTimeGetCurrent()
        let start = firstWriteTime ?? now
        let end = lastWriteTime ?? start
        return Metrics(
            bytesWritten: bytesWritten,
            startedAtTimestampNs: UInt64(start * 1_000_000_000),
            completedAtTimestampNs: UInt64(end * 1_000_000_000)
        )
    }
}
