//
//  HostFrameMotionSampler.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/28/26.
//

import CoreVideo
import Foundation

#if os(macOS)
protocol HostFrameChangeEstimator: Sendable {
    func estimate(previous: CVPixelBuffer?, current: CVPixelBuffer) -> HostFrameChangeEstimate?
}

struct HostFrameChangeEstimate: Sendable, Equatable {
    let changedAreaRatio: Double
    let averageDelta: Double
    let confidence: Double
}

struct HostFrameMotionSampler: Equatable {
    struct Sample: Equatable {
        let width: Int
        let height: Int
        let gridWidth: Int
        let gridHeight: Int
        let luma: [UInt8]
    }

    private static let defaultGridWidth = 40
    private static let defaultGridHeight = 24
    private static let changedSampleDeltaThreshold = 18
    private static let minimumSampleCount = 256

    func estimate(previous: CVPixelBuffer?, current: CVPixelBuffer) -> HostFrameChangeEstimate? {
        guard let previous,
              let previousSample = Self.sample(pixelBuffer: previous),
              let currentSample = Self.sample(pixelBuffer: current) else {
            return nil
        }
        return Self.estimate(previous: previousSample, current: currentSample)
    }

    static func sample(
        pixelBuffer: CVPixelBuffer,
        gridWidth: Int = defaultGridWidth,
        gridHeight: Int = defaultGridHeight
    ) -> Sample? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0 else { return nil }

        let columns = max(1, min(gridWidth, width))
        let rows = max(1, min(gridHeight, height))
        let lockFlags = CVPixelBufferLockFlags.readOnly
        guard CVPixelBufferLockBaseAddress(pixelBuffer, lockFlags) == kCVReturnSuccess else {
            return nil
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, lockFlags) }

        var values: [UInt8] = []
        values.reserveCapacity(columns * rows)
        for row in 0 ..< rows {
            let y = min(height - 1, Int((Double(row) + 0.5) * Double(height) / Double(rows)))
            for column in 0 ..< columns {
                let x = min(width - 1, Int((Double(column) + 0.5) * Double(width) / Double(columns)))
                guard let value = lumaValue(pixelBuffer: pixelBuffer, x: x, y: y) else {
                    return nil
                }
                values.append(value)
            }
        }

        return Sample(
            width: width,
            height: height,
            gridWidth: columns,
            gridHeight: rows,
            luma: values
        )
    }

    static func estimate(previous: Sample?, current: Sample) -> HostFrameChangeEstimate? {
        guard let previous,
              previous.width == current.width,
              previous.height == current.height,
              previous.gridWidth == current.gridWidth,
              previous.gridHeight == current.gridHeight,
              previous.luma.count == current.luma.count,
              current.luma.count >= minimumSampleCount else {
            return nil
        }

        var changedSamples = 0
        var totalDelta = 0
        for index in current.luma.indices {
            let delta = abs(Int(current.luma[index]) - Int(previous.luma[index]))
            if delta >= changedSampleDeltaThreshold { changedSamples += 1 }
            totalDelta += delta
        }

        let sampleCount = Double(current.luma.count)
        let changedSampleRatio = Double(changedSamples) / sampleCount
        let averageLumaDelta = Double(totalDelta) / sampleCount / 255.0
        let confidence = min(
            1.0,
            0.55 + min(0.30, sampleCount / 1_000.0 * 0.30) +
                min(0.15, max(changedSampleRatio, averageLumaDelta * 3.0) * 0.15)
        )
        return HostFrameChangeEstimate(
            changedAreaRatio: changedSampleRatio,
            averageDelta: averageLumaDelta,
            confidence: confidence
        )
    }

    private static func lumaValue(pixelBuffer: CVPixelBuffer, x: Int, y: Int) -> UInt8? {
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        switch pixelFormat {
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
             kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            return planar8BitLuma(pixelBuffer: pixelBuffer, x: x, y: y)
        case kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
             kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
             kCVPixelFormatType_444YpCbCr10BiPlanarFullRange:
            return planar10BitLuma(pixelBuffer: pixelBuffer, x: x, y: y)
        case kCVPixelFormatType_32BGRA:
            return bgraLuma(pixelBuffer: pixelBuffer, x: x, y: y)
        default:
            return nil
        }
    }

    private static func planar8BitLuma(pixelBuffer: CVPixelBuffer, x: Int, y: Int) -> UInt8? {
        guard CVPixelBufferGetPlaneCount(pixelBuffer) > 0,
              let baseAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else {
            return nil
        }
        let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        guard rowBytes > x else { return nil }
        let bytes = baseAddress.assumingMemoryBound(to: UInt8.self)
        return bytes[y * rowBytes + x]
    }

    private static func planar10BitLuma(pixelBuffer: CVPixelBuffer, x: Int, y: Int) -> UInt8? {
        guard CVPixelBufferGetPlaneCount(pixelBuffer) > 0,
              let baseAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else {
            return nil
        }
        let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let stride = rowBytes / MemoryLayout<UInt16>.size
        guard stride > x else { return nil }
        let words = baseAddress.assumingMemoryBound(to: UInt16.self)
        let value = Int(words[y * stride + x] >> 8)
        return UInt8(max(0, min(255, value)))
    }

    private static func bgraLuma(pixelBuffer: CVPixelBuffer, x: Int, y: Int) -> UInt8? {
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let offset = y * rowBytes + x * 4
        guard rowBytes >= (x + 1) * 4 else { return nil }
        let bytes = baseAddress.assumingMemoryBound(to: UInt8.self)
        let blue = Int(bytes[offset])
        let green = Int(bytes[offset + 1])
        let red = Int(bytes[offset + 2])
        return UInt8((red * 77 + green * 150 + blue * 29) >> 8)
    }
}
#endif
