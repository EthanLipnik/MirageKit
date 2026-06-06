//
//  StreamContextMosaicMediaUnitCropperTests.swift
//  MirageKitHost
//
//  Created by Ethan Lipnik on 6/6/26.
//

#if os(macOS)
@testable import MirageKitHost
import CoreGraphics
import CoreVideo
import CoreMedia
import MirageMedia
import Testing

@Suite("StreamContext Mosaic Media Unit Cropper")
struct StreamContextMosaicMediaUnitCropperTests {
    @Test("Cropper extracts planned codec-unit pixels")
    func cropperExtractsPlannedCodecUnitPixels() throws {
        let source = try makeBGRA(width: 6, height: 2)
        let plan = MirageMosaicTilePlan.fixedGrid(
            logicalSize: MiragePixelSize(width: 6, height: 2),
            columns: 3,
            rows: 1,
            codec: .hevc
        )
        let summary = MirageMosaicEpochSummary(
            tilePlanID: plan.id,
            tilePlanEpoch: plan.epoch,
            frameNumber: 1,
            dirtyTileIDs: [MirageMosaicTileID(rawValue: "grid-1")],
            reusedTileVersions: [:],
            updatedTileVersions: [MirageMosaicTileID(rawValue: "grid-1"): 1]
        )
        let unit = try #require(StreamContextMosaicMediaUnitPlanner()
            .plannedUnits(plan: plan, summary: summary)
            .only)

        let result = try #require(StreamContextMosaicMediaUnitCropper().crop(source, unit: unit))

        #expect(CVPixelBufferGetWidth(result.pixelBuffer) == 2)
        #expect(CVPixelBufferGetHeight(result.pixelBuffer) == 2)
        #expect(pixelBytes(in: result.pixelBuffer, x: 0, y: 0) == pixelBytes(in: source, x: 2, y: 0))
        #expect(pixelBytes(in: result.pixelBuffer, x: 1, y: 1) == pixelBytes(in: source, x: 3, y: 1))

        let frame = CapturedFrame(
            pixelBuffer: source,
            presentationTime: CMTime(seconds: 3, preferredTimescale: 600),
            duration: CMTime(value: 1, timescale: 60),
            captureTime: 12,
            info: CapturedFrameInfo(
                contentRect: CGRect(x: 0, y: 0, width: 6, height: 2),
                dirtyPercentage: 10,
                isIdleFrame: false
            )
        )
        let croppedFrame = try #require(StreamContextMosaicMediaUnitCropper().croppedFrame(
            from: frame,
            unit: unit
        ))
        #expect(CVPixelBufferGetWidth(croppedFrame.pixelBuffer) == 2)
        #expect(CVPixelBufferGetHeight(croppedFrame.pixelBuffer) == 2)
        #expect(croppedFrame.presentationTime == frame.presentationTime)
        #expect(croppedFrame.duration == frame.duration)
        #expect(croppedFrame.captureTime == frame.captureTime)
        #expect(croppedFrame.info.contentRect == CGRect(x: 0, y: 0, width: 2, height: 2))
    }

    private func makeBGRA(width: Int, height: Int) throws -> CVPixelBuffer {
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &pixelBuffer
        )
        let buffer = try #require(pixelBuffer, "Failed to allocate CVPixelBuffer: \(status)")

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        let baseAddress = try #require(CVPixelBufferGetBaseAddress(buffer))
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0 ..< height {
            let row = baseAddress
                .advanced(by: y * bytesPerRow)
                .assumingMemoryBound(to: UInt8.self)
            for x in 0 ..< width {
                let offset = x * 4
                row[offset] = UInt8(x)
                row[offset + 1] = UInt8(y)
                row[offset + 2] = UInt8(x + y)
                row[offset + 3] = 255
            }
        }
        return buffer
    }

    private func pixelBytes(in buffer: CVPixelBuffer, x: Int, y: Int) -> [UInt8] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(buffer) else { return [] }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let pixel = baseAddress
            .advanced(by: y * bytesPerRow + x * 4)
            .assumingMemoryBound(to: UInt8.self)
        return Array(UnsafeBufferPointer(start: pixel, count: 4))
    }
}

private extension Array {
    var only: Element? {
        count == 1 ? self[0] : nil
    }
}
#endif
