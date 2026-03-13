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

private struct HEVCBitReader {
    private let bytes: [UInt8]
    private var byteIndex = 0
    private var bitIndex = 0

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    mutating func readBit() -> UInt8? {
        guard byteIndex < bytes.count else { return nil }
        let value = (bytes[byteIndex] >> (7 - bitIndex)) & 0x01
        bitIndex += 1
        if bitIndex == 8 {
            bitIndex = 0
            byteIndex += 1
        }
        return value
    }

    mutating func readBits(_ count: Int) -> UInt64? {
        guard count >= 0 else { return nil }
        var result: UInt64 = 0
        for _ in 0 ..< count {
            guard let bit = readBit() else { return nil }
            result = (result << 1) | UInt64(bit)
        }
        return result
    }

    mutating func skipBits(_ count: Int) -> Bool {
        readBits(count) != nil
    }

    mutating func readUnsignedExpGolomb() -> UInt64? {
        var leadingZeroBits = 0
        while let bit = readBit() {
            if bit == 0 {
                leadingZeroBits += 1
                continue
            }

            guard leadingZeroBits < 63 else { return nil }
            if leadingZeroBits == 0 {
                return 0
            }
            guard let suffix = readBits(leadingZeroBits) else { return nil }
            return (UInt64(1) << UInt64(leadingZeroBits)) - 1 + suffix
        }

        return nil
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

    static func chromaSampling(from formatDescription: CMFormatDescription) -> MirageStreamChromaSampling? {
        guard let sps = hevcParameterSetData(from: formatDescription, index: 1) else {
            return nil
        }
        return hevcChromaSampling(fromSPS: sps)
    }

    static func hevcChromaSampling(fromSPS sps: Data) -> MirageStreamChromaSampling? {
        let rbsp = hevcRBSP(fromParameterSet: sps)
        guard !rbsp.isEmpty else { return nil }

        var reader = HEVCBitReader(bytes: rbsp)
        guard reader.skipBits(4),
              let maxSubLayersMinus1 = reader.readBits(3),
              reader.skipBits(1),
              skipHEVCProfileTierLevel(&reader, maxSubLayersMinus1: Int(maxSubLayersMinus1)),
              reader.readUnsignedExpGolomb() != nil,
              let chromaFormatIDC = reader.readUnsignedExpGolomb() else {
            return nil
        }

        switch chromaFormatIDC {
        case 1:
            return .yuv420
        case 2:
            return .yuv422
        case 3:
            return .yuv444
        default:
            return nil
        }
    }

    private static func hevcParameterSetData(
        from formatDescription: CMFormatDescription,
        index: Int
    ) -> Data? {
        var pointer: UnsafePointer<UInt8>?
        var size = 0
        let status = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
            formatDescription,
            parameterSetIndex: index,
            parameterSetPointerOut: &pointer,
            parameterSetSizeOut: &size,
            parameterSetCountOut: nil,
            nalUnitHeaderLengthOut: nil
        )
        guard status == noErr, let pointer, size > 0 else {
            return nil
        }
        return Data(bytes: pointer, count: size)
    }

    private static func hevcRBSP(fromParameterSet parameterSet: Data) -> [UInt8] {
        let payload: Data
        if parameterSet.count > 2 {
            payload = parameterSet.dropFirst(2)
        } else {
            payload = parameterSet
        }

        var rbsp: [UInt8] = []
        rbsp.reserveCapacity(payload.count)

        var consecutiveZeros = 0
        for byte in payload {
            if consecutiveZeros == 2, byte == 0x03 {
                consecutiveZeros = 0
                continue
            }

            rbsp.append(byte)
            if byte == 0 {
                consecutiveZeros += 1
            } else {
                consecutiveZeros = 0
            }
        }

        return rbsp
    }

    private static func skipHEVCProfileTierLevel(
        _ reader: inout HEVCBitReader,
        maxSubLayersMinus1: Int
    ) -> Bool {
        guard reader.skipBits(96) else { return false }

        var profilePresentFlags: [Bool] = []
        var levelPresentFlags: [Bool] = []
        profilePresentFlags.reserveCapacity(maxSubLayersMinus1)
        levelPresentFlags.reserveCapacity(maxSubLayersMinus1)

        for _ in 0 ..< maxSubLayersMinus1 {
            guard let profilePresent = reader.readBit(),
                  let levelPresent = reader.readBit() else {
                return false
            }
            profilePresentFlags.append(profilePresent == 1)
            levelPresentFlags.append(levelPresent == 1)
        }

        if maxSubLayersMinus1 > 0 {
            guard reader.skipBits((8 - maxSubLayersMinus1) * 2) else { return false }
        }

        for index in 0 ..< maxSubLayersMinus1 {
            if profilePresentFlags[index], !reader.skipBits(88) {
                return false
            }
            if levelPresentFlags[index], !reader.skipBits(8) {
                return false
            }
        }

        return true
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
