//
//  DirtyRegionDetector.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//

import CoreVideo
import Foundation
import MirageKit

#if os(macOS)
/// Detects the bounding rectangle of changed pixels between frames
/// Used for future partial-frame encoding optimization
final class DirtyRegionDetector: @unchecked Sendable {
    private var previousBuffer: CVPixelBuffer?
    private let blockSize: Int = 16 // Scan in 16x16 blocks for efficiency

    /// Result of dirty region detection
    struct DetectionResult {
        /// Bounding rectangle of all changed pixels (nil if no changes)
        let dirtyRect: CGRect?
        /// Percentage of frame that changed (0.0 - 1.0)
        let changePercentage: Float
        /// Whether the change is considered "small" (< 5% of frame)
        let isSmallChange: Bool
    }

    /// Detect dirty region by comparing current frame to previous
    /// Returns nil on first frame or if comparison not possible
    func detectDirtyRegion(currentBuffer: CVPixelBuffer) -> DetectionResult? {
        defer {
            // Store current buffer for next comparison
            previousBuffer = currentBuffer
        }

        // First frame, nothing to compare
        guard let previous = previousBuffer else { return nil }

        // Lock both buffers
        CVPixelBufferLockBaseAddress(currentBuffer, .readOnly)
        CVPixelBufferLockBaseAddress(previous, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(currentBuffer, .readOnly)
            CVPixelBufferUnlockBaseAddress(previous, .readOnly)
        }

        guard let currentBase = CVPixelBufferGetBaseAddress(currentBuffer),
              let previousBase = CVPixelBufferGetBaseAddress(previous) else {
            return nil
        }

        let width = CVPixelBufferGetWidth(currentBuffer)
        let height = CVPixelBufferGetHeight(currentBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(currentBuffer)

        // Ensure dimensions match
        guard width == CVPixelBufferGetWidth(previous),
              height == CVPixelBufferGetHeight(previous) else {
            return DetectionResult(
                dirtyRect: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)),
                changePercentage: 1.0,
                isSmallChange: false
            )
        }

        var minX = width, maxX = 0, minY = height, maxY = 0
        var changedBlocks = 0
        let totalBlocks = ((width + blockSize - 1) / blockSize) * ((height + blockSize - 1) / blockSize)

        // Scan in blocks for efficiency
        for blockY in stride(from: 0, to: height, by: blockSize) {
            for blockX in stride(from: 0, to: width, by: blockSize) {
                // Sample center of block
                let x = min(blockX + blockSize / 2, width - 1)
                let y = min(blockY + blockSize / 2, height - 1)
                let offset = y * bytesPerRow + x * 4

                let currentPixel = currentBase.load(fromByteOffset: offset, as: UInt32.self)
                let previousPixel = previousBase.load(fromByteOffset: offset, as: UInt32.self)

                if currentPixel != previousPixel {
                    changedBlocks += 1
                    minX = min(minX, blockX)
                    maxX = max(maxX, min(blockX + blockSize, width))
                    minY = min(minY, blockY)
                    maxY = max(maxY, min(blockY + blockSize, height))
                }
            }
        }

        let changePercentage = Float(changedBlocks) / Float(max(1, totalBlocks))

        if changedBlocks == 0 { return DetectionResult(dirtyRect: nil, changePercentage: 0, isSmallChange: true) }

        let dirtyRect = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        let isSmallChange = changePercentage < 0.05 // Less than 5% changed

        return DetectionResult(dirtyRect: dirtyRect, changePercentage: changePercentage, isSmallChange: isSmallChange)
    }

    /// Reset the detector (e.g., after dimension change)
    func reset() {
        previousBuffer = nil
    }
}

#endif
