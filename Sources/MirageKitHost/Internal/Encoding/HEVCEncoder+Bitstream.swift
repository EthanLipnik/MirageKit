//
//  HEVCEncoder+Bitstream.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  HEVC encoder extensions.
//

import CoreMedia
import Foundation
import VideoToolbox
import MirageKit

#if os(macOS)
import ScreenCaptureKit

enum HEVCLengthPrefixedValidationResult: Equatable, Sendable {
    case valid
    case emptyPayload
    case zeroLengthNAL(offset: Int)
    case truncatedNAL(offset: Int, declaredLength: Int, availableBytes: Int)
    case trailingBytes(offset: Int)

    var isValid: Bool {
        if case .valid = self { return true }
        return false
    }

    var logSummary: String {
        switch self {
        case .valid:
            "valid"
        case .emptyPayload:
            "empty payload"
        case let .zeroLengthNAL(offset):
            "zero-length NAL at offset \(offset)"
        case let .truncatedNAL(offset, declaredLength, availableBytes):
            "truncated NAL at offset \(offset) (declared=\(declaredLength), available=\(availableBytes))"
        case let .trailingBytes(offset):
            "trailing bytes after NAL walk at offset \(offset)"
        }
    }
}

extension HEVCEncoder {
    static func isKeyframe(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[CFString: Any]],
            let attachment = attachments.first else {
            return false
        }

        // If DependsOnOthers is false or not present, it's a keyframe
        if let dependsOnOthers = attachment[kCMSampleAttachmentKey_DependsOnOthers] as? Bool { return !dependsOnOthers }

        return true
    }

    static func extractParameterSets(from formatDescription: CMFormatDescription) -> Data? {
        var result = Data()
        let startCode: [UInt8] = [0x00, 0x00, 0x00, 0x01]

        // Get the number of parameter sets by querying index 0
        var parameterSetCount = 0
        var nalUnitHeaderLength: Int32 = 0
        var status = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
            formatDescription,
            parameterSetIndex: 0,
            parameterSetPointerOut: nil,
            parameterSetSizeOut: nil,
            parameterSetCountOut: &parameterSetCount,
            nalUnitHeaderLengthOut: &nalUnitHeaderLength
        )

        // Log the result for debugging
        MirageLogger
            .encoder(
                "Parameter set query: status=\(status), count=\(parameterSetCount), nalHeaderLen=\(nalUnitHeaderLength)"
            )

        guard status == noErr else {
            MirageLogger.error(.encoder, "Failed to get parameter set count: \(status)")
            return nil
        }

        guard parameterSetCount >= 3 else {
            MirageLogger.error(.encoder, "Not enough parameter sets: \(parameterSetCount)")
            return nil
        }

        // Extract each parameter set (VPS at 0, SPS at 1, PPS at 2)
        for i in 0 ..< parameterSetCount {
            var parameterSetPointer: UnsafePointer<UInt8>?
            var parameterSetSize = 0

            status = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                formatDescription,
                parameterSetIndex: i,
                parameterSetPointerOut: &parameterSetPointer,
                parameterSetSizeOut: &parameterSetSize,
                parameterSetCountOut: nil,
                nalUnitHeaderLengthOut: nil
            )

            guard status == noErr, let pointer = parameterSetPointer else {
                MirageLogger.error(.encoder, "Failed to get parameter set \(i): \(status)")
                continue
            }

            // Append start code + parameter set
            result.append(contentsOf: startCode)
            result.append(pointer, count: parameterSetSize)
        }

        if result.isEmpty { return nil }

        MirageLogger.encoder("Extracted \(parameterSetCount) parameter sets")
        return result
    }

    static func validateLengthPrefixedHEVCBitstream(_ data: Data) -> HEVCLengthPrefixedValidationResult {
        guard !data.isEmpty else { return .emptyPayload }

        var cursor = 0
        let count = data.count

        while cursor + 4 <= count {
            let nalLength = Int(data[cursor]) << 24 |
                Int(data[cursor + 1]) << 16 |
                Int(data[cursor + 2]) << 8 |
                Int(data[cursor + 3])

            guard nalLength > 0 else { return .zeroLengthNAL(offset: cursor) }
            cursor += 4

            let remaining = count - cursor
            guard nalLength <= remaining else {
                return .truncatedNAL(
                    offset: cursor - 4,
                    declaredLength: nalLength,
                    availableBytes: remaining
                )
            }

            cursor += nalLength
        }

        guard cursor == count else { return .trailingBytes(offset: cursor) }
        return .valid
    }
}

#endif
