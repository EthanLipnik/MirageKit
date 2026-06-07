//
//  VideoDecoder+AVCCValidation.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/12/26.
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
import Foundation

enum AVCCValidationResult: Equatable, Sendable {
    case valid
    case empty
    case annexBDetected
    case zeroLengthNAL(offset: Int)
    case truncatedNAL(offset: Int, declared: Int, available: Int)
    case trailingBytes(validEnd: Int, totalCount: Int)

    var isValid: Bool {
        if case .valid = self { return true }
        return false
    }

    var logSummary: String {
        switch self {
        case .valid:
            "valid"
        case .empty:
            "empty payload"
        case .annexBDetected:
            "Annex-B start codes detected (not AVCC)"
        case let .zeroLengthNAL(offset):
            "zero-length NAL at offset \(offset)"
        case let .truncatedNAL(offset, declared, available):
            "truncated NAL at offset \(offset): declared \(declared) bytes, only \(available) available"
        case let .trailingBytes(validEnd, totalCount):
            "trailing bytes: valid data ends at \(validEnd), total \(totalCount) (\(totalCount - validEnd) extra bytes)"
        }
    }
}

extension VideoDecoder {
    /// Validates that the provided HEVC bitstream uses 4-byte AVCC length prefixes.
    func validateLengthPrefixedHEVCBitstream(_ data: Data) -> AVCCValidationResult {
        guard !data.isEmpty else { return .empty }

        // Try the AVCC structural walk first. A valid walk proves the data IS
        // length-prefixed AVCC even when the first bytes happen to look like an
        // Annex-B start code (e.g. a NAL length of 0x0001XX -> `00 00 01 XX`).
        var cursor = 0
        let count = data.count
        while cursor + 4 <= count {
            let nalLength = Int(data[cursor]) << 24 |
                Int(data[cursor + 1]) << 16 |
                Int(data[cursor + 2]) << 8 |
                Int(data[cursor + 3])
            guard nalLength > 0 else {
                if cursor == 0 && data.starts(with: [0x00, 0x00, 0x00, 0x01]) {
                    return .annexBDetected
                }
                return .zeroLengthNAL(offset: cursor)
            }

            let nalEnd = cursor + 4 + nalLength
            guard nalEnd <= count else {
                if cursor == 0 &&
                    (data.starts(with: [0x00, 0x00, 0x00, 0x01]) || data.starts(with: [0x00, 0x00, 0x01])) {
                    return .annexBDetected
                }
                return .truncatedNAL(offset: cursor, declared: nalLength, available: count - cursor - 4)
            }
            cursor = nalEnd
        }

        guard cursor == count else { return .trailingBytes(validEnd: cursor, totalCount: count) }
        return .valid
    }

    /// Walks AVCC 4-byte length prefixes and returns the valid prefix, if any NAL units are complete.
    func trimToValidAVCCBoundary(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }

        var cursor = 0
        var lastValidCursor = 0
        let count = data.count

        while cursor + 4 <= count {
            let nalLength = Int(data[cursor]) << 24 |
                Int(data[cursor + 1]) << 16 |
                Int(data[cursor + 2]) << 8 |
                Int(data[cursor + 3])
            guard nalLength > 0 else { break }

            let nalEnd = cursor + 4 + nalLength
            guard nalEnd <= count else { break }

            cursor = nalEnd
            lastValidCursor = cursor
        }

        guard lastValidCursor > 0 else { return nil }
        return data.prefix(lastValidCursor)
    }
}
