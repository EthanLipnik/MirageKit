//
//  HEVCDecoder+Format.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  HEVC decoder extensions.
//

import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox
import MirageKit

extension HEVCDecoder {
    func extractFormatDescriptionAndStripParameterSets(from data: Data) throws -> Data {
        // Check for framed keyframe format (4-byte length prefix + Annex B parameter sets + AVCC frame data)
        if let framed = splitFramedKeyframeData(from: data) {
            // Extract VPS, SPS, PPS from the parameter sets portion
            let (vps, sps, pps) = extractParameterSets(from: framed.parameterSets)
            if let vpsData = vps, let spsData = sps, let ppsData = pps {
                cachedVPS = vpsData
                cachedSPS = spsData
                cachedPPS = ppsData
                try updateFormatDescription(vpsData: vpsData, spsData: spsData, ppsData: ppsData)
                // Return the frame data portion (already stripped of parameter sets)
                var strippedData = framed.frameData
                strippedData = stripSEINALUnits(from: strippedData)
                return strippedData
            }
        }

        // Parse HEVC NAL units to extract VPS, SPS, PPS (in Annex B format)
        // NAL unit types: VPS=32, SPS=33, PPS=34
        // After parameter sets, the data transitions to AVCC format (length-prefixed, no start codes)

        // First, find all start code positions in the first 200 bytes
        // Parameter sets are small (~85 bytes total with start codes)
        var startCodePositions: [(position: Int, length: Int)] = []
        var i = 0
        let searchLimit = min(data.count, 200)

        while i < searchLimit - 3 {
            if data[i] == 0x00, data[i + 1] == 0x00 {
                if data[i + 2] == 0x01 {
                    startCodePositions.append((i, 3))
                    i += 3
                    continue
                } else if i + 3 < searchLimit, data[i + 2] == 0x00, data[i + 3] == 0x01 {
                    startCodePositions.append((i, 4))
                    i += 4
                    continue
                }
            }
            i += 1
        }

        guard startCodePositions.count >= 3 else {
            MirageLogger.error(.decoder, "Not enough start codes found: \(startCodePositions.count)")
            return data
        }

        var vps: Data?
        var sps: Data?
        var pps: Data?
        var parameterSetsEnd = 0

        // Extract each NAL unit between consecutive start codes
        for (idx, startCode) in startCodePositions.enumerated() {
            let nalStart = startCode.position + startCode.length
            let nalEnd: Int = if idx + 1 < startCodePositions.count {
                // NAL ends where next start code begins
                startCodePositions[idx + 1].position
            } else {
                // Last start code - this is PPS, need to find where AVCC starts
                // Scan forward from NAL start looking for AVCC length prefix
                findAVCCBoundary(in: data, after: nalStart)
            }

            guard nalEnd > nalStart, nalStart < data.count else { continue }
            let actualEnd = min(nalEnd, data.count)
            let nalData = data.subdata(in: nalStart ..< actualEnd)
            guard !nalData.isEmpty else { continue }

            // HEVC NAL unit header is 2 bytes
            // NAL type is in bits 1-6 of first byte (shift right by 1, mask with 0x3F)
            let nalType = (nalData[0] >> 1) & 0x3F

            switch nalType {
            case 32: // VPS
                vps = nalData
                parameterSetsEnd = nalEnd
            case 33: // SPS
                sps = nalData
                parameterSetsEnd = nalEnd
            case 34: // PPS
                pps = nalData
                parameterSetsEnd = nalEnd
            default:
                break
            }
        }

        // Need all three parameter sets
        guard let vpsData = vps, let spsData = sps, let ppsData = pps else {
            MirageLogger.error(
                .decoder,
                "Missing parameter sets - VPS: \(vps != nil), SPS: \(sps != nil), PPS: \(pps != nil)"
            )

            // Try to use cached format description if available
            if let cached = cachedFormatDescription {
                MirageLogger.decoder("Using cached format description due to corrupted keyframe")
                formatDescription = cached
            }

            return data // Return original data, will try again on next keyframe
        }

        // Cache the parameter sets for resilience
        cachedVPS = vpsData
        cachedSPS = spsData
        cachedPPS = ppsData

        try updateFormatDescription(vpsData: vpsData, spsData: spsData, ppsData: ppsData)

        // Return data with parameter sets stripped (the remaining AVCC data)
        if parameterSetsEnd > 0, parameterSetsEnd < data.count {
            var strippedData = Data(data.suffix(from: parameterSetsEnd))

            // Strip any leading SEI NAL units that may confuse VideoToolbox
            // SEI (Supplemental Enhancement Information) contains metadata like HDR info
            // VideoToolbox may not properly decode IDR when SEI comes first
            strippedData = stripSEINALUnits(from: strippedData)

            return strippedData
        }

        return data
    }

    private func splitFramedKeyframeData(from data: Data) -> (parameterSets: Data, frameData: Data)? {
        guard data.count > 8 else { return nil }

        let length = UInt32(data[0]) << 24 |
            UInt32(data[1]) << 16 |
            UInt32(data[2]) << 8 |
            UInt32(data[3])
        guard length > 0 else { return nil }

        let start = 4
        let end = start + Int(length)
        guard end > start, end <= data.count else { return nil }

        let parameterSets = data.subdata(in: start ..< end)
        let hasStartCode = parameterSets.starts(with: [0x00, 0x00, 0x00, 0x01]) ||
            parameterSets.starts(with: [0x00, 0x00, 0x01])
        guard hasStartCode else { return nil }

        let frameData = data.subdata(in: end ..< data.count)
        guard !frameData.isEmpty else { return nil }

        return (parameterSets, frameData)
    }

    private func extractParameterSets(from data: Data) -> (vps: Data?, sps: Data?, pps: Data?) {
        var startCodePositions: [(position: Int, length: Int)] = []
        var i = 0
        let searchLimit = max(0, data.count - 3)

        while i < searchLimit {
            if data[i] == 0x00, data[i + 1] == 0x00 {
                if data[i + 2] == 0x01 {
                    startCodePositions.append((i, 3))
                    i += 3
                    continue
                } else if i + 3 < data.count, data[i + 2] == 0x00, data[i + 3] == 0x01 {
                    startCodePositions.append((i, 4))
                    i += 4
                    continue
                }
            }
            i += 1
        }

        guard startCodePositions.count >= 3 else {
            MirageLogger.error(.decoder, "Not enough start codes found: \(startCodePositions.count)")
            return (nil, nil, nil)
        }

        var vps: Data?
        var sps: Data?
        var pps: Data?

        for (idx, startCode) in startCodePositions.enumerated() {
            let nalStart = startCode.position + startCode.length
            let nalEnd = idx + 1 < startCodePositions.count ? startCodePositions[idx + 1].position : data.count

            guard nalEnd > nalStart, nalStart < data.count else { continue }
            let nalData = data.subdata(in: nalStart ..< nalEnd)
            guard !nalData.isEmpty else { continue }

            let nalType = (nalData[0] >> 1) & 0x3F
            switch nalType {
            case 32:
                vps = nalData
            case 33:
                sps = nalData
            case 34:
                pps = nalData
            default:
                break
            }
        }

        return (vps, sps, pps)
    }

    func isValidLengthPrefixedHEVCBitstream(_ data: Data) -> Bool {
        guard !data.isEmpty else { return false }
        if data.starts(with: [0x00, 0x00, 0x00, 0x01]) || data.starts(with: [0x00, 0x00, 0x01]) {
            return false
        }

        var cursor = 0
        let count = data.count
        while cursor + 4 <= count {
            let nalLength = Int(data[cursor]) << 24 |
                Int(data[cursor + 1]) << 16 |
                Int(data[cursor + 2]) << 8 |
                Int(data[cursor + 3])
            guard nalLength > 0 else { return false }

            cursor += 4
            guard cursor + nalLength <= count else { return false }
            cursor += nalLength
        }

        return cursor == count
    }

    private func updateFormatDescription(vpsData: Data, spsData: Data, ppsData: Data) throws {
        try vpsData.withUnsafeBytes { vpsPtr in
            try spsData.withUnsafeBytes { spsPtr in
                try ppsData.withUnsafeBytes { ppsPtr in
                    let parameterSetPointers: [UnsafePointer<UInt8>] = [
                        vpsPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                        spsPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                        ppsPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    ]
                    let parameterSetSizes: [Int] = [vpsData.count, spsData.count, ppsData.count]

                    var formatDesc: CMFormatDescription?
                    let status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                        allocator: kCFAllocatorDefault,
                        parameterSetCount: 3,
                        parameterSetPointers: parameterSetPointers,
                        parameterSetSizes: parameterSetSizes,
                        nalUnitHeaderLength: 4,
                        extensions: nil,
                        formatDescriptionOut: &formatDesc
                    )

                    guard status == noErr, let desc = formatDesc else {
                        if let cached = self.cachedFormatDescription {
                            MirageLogger.decoder("Format description creation failed (status \(status)), using cached")
                            self.formatDescription = cached
                            return
                        }
                        throw MirageError.decodingError(NSError(
                            domain: NSOSStatusErrorDomain,
                            code: Int(status),
                            userInfo: [NSLocalizedDescriptionKey: "Failed to create format description"]
                        ))
                    }

                    let oldDims = self.formatDescription.flatMap { CMVideoFormatDescriptionGetDimensions($0) }
                    let newDims = CMVideoFormatDescriptionGetDimensions(desc)

                    let dimensionsMismatch = oldDims.map { old in
                        old.width != newDims.width || old.height != newDims.height
                    } ?? false

                    let isFirstKeyframe = oldDims == nil
                    let shouldRecreateForErrors = !isFirstKeyframe &&
                        (self.errorTracker?.shouldRecreateSession() ?? false)
                    let shouldRecreateSession = dimensionsMismatch || shouldRecreateForErrors

                    if isFirstKeyframe {
                        MirageLogger
                            .decoder(
                                "First keyframe - session will be created fresh (\(newDims.width)x\(newDims.height))"
                            )
                    }

                    if shouldRecreateSession {
                        if dimensionsMismatch, let old = oldDims {
                            MirageLogger
                                .decoder(
                                    "Dimensions changed from \(old.width)x\(old.height) to \(newDims.width)x\(newDims.height) - recreating session"
                                )
                        } else if shouldRecreateForErrors {
                            MirageLogger
                                .decoder(
                                    "Recreating session due to decode errors (dimensions unchanged: \(newDims.width)x\(newDims.height))"
                                )
                        }

                        if let session = self.decompressionSession {
                            VTDecompressionSessionInvalidate(session)
                            self.decompressionSession = nil
                        }

                        if dimensionsMismatch {
                            // A keyframe carrying the new dimensions is already in-flight and
                            // being processed here. Triggering another threshold-based keyframe
                            // recovery causes an avoidable keyframe-only stall loop during resize.
                            self.onDimensionChange?()
                            self.errorTracker?.clearForDimensionChange()
                        } else if shouldRecreateForErrors {
                            self.errorTracker?.markSessionRecreated()
                        }
                    }

                    self.outputPixelFormat = preferredOutputPixelFormat(for: desc)
                    self.formatDescription = desc
                    self.cachedFormatDescription = desc
                    MirageLogger.decoder("Created format description successfully (\(newDims.width)x\(newDims.height))")

                    if self.awaitingDimensionChange {
                        self.awaitingDimensionChange = false
                        self.expectedDimensions = nil
                        MirageLogger.decoder("Dimension change complete - resuming normal P-frame processing")
                    }
                }
            }
        }
    }

    private func preferredOutputPixelFormat(for formatDescription: CMFormatDescription) -> OSType {
        guard let extensions = CMFormatDescriptionGetExtensions(formatDescription) as? [CFString: Any],
              let bits = extensions[kCMFormatDescriptionExtension_BitsPerComponent] as? Int else {
            return kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        }
        return bits > 8 ? kCVPixelFormatType_420YpCbCr10BiPlanarFullRange :
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
    }

    private func stripSEINALUnits(from data: Data) -> Data {
        var result = data

        while result.count > 5 {
            // Read AVCC length (4 bytes big-endian)
            let length = UInt32(result[0]) << 24 |
                UInt32(result[1]) << 16 |
                UInt32(result[2]) << 8 |
                UInt32(result[3])

            // Sanity check: length must be reasonable
            guard length > 0 && length < result.count - 4 else { break }

            // Read NAL type from 5th byte (first byte after length prefix)
            // HEVC NAL header: forbidden_zero_bit(1) | nal_unit_type(6) | nuh_layer_id_high(1)
            let nalType = (result[4] >> 1) & 0x3F

            // SEI NAL types: 39 (PREFIX_SEI_NUT), 40 (SUFFIX_SEI_NUT)
            if nalType == 39 || nalType == 40 {
                // Skip this SEI NAL unit (4-byte length prefix + NAL data)
                let skipBytes = 4 + Int(length)
                if skipBytes < result.count {
                    result = Data(result.dropFirst(skipBytes))
                    MirageLogger.decoder("Stripped SEI NAL (type \(nalType), \(length) bytes)")
                    continue
                }
            }

            // Not a SEI, stop stripping
            break
        }

        return result
    }

    private func findAVCCBoundary(in data: Data, after nalStart: Int) -> Int {
        // PPS NAL is typically 5-15 bytes. Scan forward looking for AVCC length prefix.
        // Skip the 2-byte NAL header first
        var pos = nalStart + 2
        let scanLimit = min(data.count - 4, nalStart + 50)

        while pos < scanLimit {
            // Read 4 bytes as potential AVCC length (big-endian)
            let b0 = UInt32(data[pos])
            let b1 = UInt32(data[pos + 1])
            let b2 = UInt32(data[pos + 2])
            let b3 = UInt32(data[pos + 3])
            let potentialLength = (b0 << 24) | (b1 << 16) | (b2 << 8) | b3

            // Check if this could be a start code (we're still in Annex B)
            if b0 == 0x00, b1 == 0x00, b2 == 0x01 || (b2 == 0x00 && b3 == 0x01) {
                // Found another start code, boundary is here
                return pos
            }

            // Check if this looks like a valid AVCC length:
            // - Not 0 or 1 (too small for a NAL)
            // - Reasonable size for a video NAL (> 10 bytes, < remaining data)
            let remainingData = data.count - pos - 4
            if potentialLength > 10, potentialLength < remainingData {
                // This looks like AVCC, boundary is here
                return pos
            }

            pos += 1
        }

        // Fallback: assume PPS is about 10 bytes
        return min(nalStart + 10, data.count)
    }

    private func parseNALUnitsWithPositions(from data: Data) -> [(Data, Int)] {
        var nalUnits: [(Data, Int)] = []
        var currentIndex = 0

        while currentIndex < data.count {
            // Look for start code (0x00 0x00 0x01 or 0x00 0x00 0x00 0x01)
            var startCodeLength = 0
            var foundStartCode = false

            if currentIndex + 3 <= data.count {
                if data[currentIndex] == 0x00, data[currentIndex + 1] == 0x00 {
                    if data[currentIndex + 2] == 0x01 {
                        startCodeLength = 3
                        foundStartCode = true
                    } else if currentIndex + 4 <= data.count,
                              data[currentIndex + 2] == 0x00, data[currentIndex + 3] == 0x01 {
                        startCodeLength = 4
                        foundStartCode = true
                    }
                }
            }

            if foundStartCode {
                currentIndex += startCodeLength

                // Find next start code or end of data
                var nextStart = currentIndex
                while nextStart < data.count {
                    if nextStart + 3 <= data.count,
                       data[nextStart] == 0x00, data[nextStart + 1] == 0x00,
                       data[nextStart + 2] == 0x01 ||
                       (nextStart + 4 <= data.count && data[nextStart + 2] == 0x00 && data[nextStart + 3] == 0x01) {
                        break
                    }
                    nextStart += 1
                }

                // Extract NAL unit
                if nextStart > currentIndex {
                    let nalUnit = data.subdata(in: currentIndex ..< nextStart)
                    nalUnits.append((nalUnit, nextStart))
                }
                currentIndex = nextStart
            } else {
                // No more Annex B start codes found, remaining data is AVCC format
                break
            }
        }

        return nalUnits
    }

    private func parseNALUnits(from data: Data) -> [Data] {
        var nalUnits: [Data] = []
        var currentIndex = 0

        while currentIndex < data.count {
            // Look for start code (0x00 0x00 0x01 or 0x00 0x00 0x00 0x01)
            var startCodeLength = 0
            var foundStartCode = false

            if currentIndex + 3 <= data.count {
                if data[currentIndex] == 0x00, data[currentIndex + 1] == 0x00 {
                    if data[currentIndex + 2] == 0x01 {
                        startCodeLength = 3
                        foundStartCode = true
                    } else if currentIndex + 4 <= data.count,
                              data[currentIndex + 2] == 0x00, data[currentIndex + 3] == 0x01 {
                        startCodeLength = 4
                        foundStartCode = true
                    }
                }
            }

            if foundStartCode {
                currentIndex += startCodeLength

                // Find next start code or end of data
                var nextStart = currentIndex
                while nextStart < data.count {
                    if nextStart + 3 <= data.count,
                       data[nextStart] == 0x00, data[nextStart + 1] == 0x00,
                       data[nextStart + 2] == 0x01 ||
                       (nextStart + 4 <= data.count && data[nextStart + 2] == 0x00 && data[nextStart + 3] == 0x01) {
                        break
                    }
                    nextStart += 1
                }

                // Extract NAL unit
                if nextStart > currentIndex {
                    let nalUnit = data.subdata(in: currentIndex ..< nextStart)
                    nalUnits.append(nalUnit)
                }
                currentIndex = nextStart
            } else {
                currentIndex += 1
            }
        }

        return nalUnits
    }
}
