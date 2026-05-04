//
//  MiragePixelBufferCropperTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/4/26.
//

#if os(macOS)
@testable import MirageKitClient
import CoreGraphics
import CoreVideo
import Testing

@Suite("Pixel Buffer Cropper")
struct MiragePixelBufferCropperTests {
    @Test("Cropping BGRA atlas returns only requested pixels")
    func croppingBGRAAtlasReturnsRequestedPixels() throws {
        let source = try makeBGRAAtlas(width: 6, height: 4)
        let cropper = MiragePixelBufferCropper()

        let result = try #require(
            cropper.crop(source, to: CGRect(x: 2, y: 1, width: 3, height: 2))
        )

        #expect(!result.usedOriginalBuffer)
        #expect(CVPixelBufferGetWidth(result.pixelBuffer) == 3)
        #expect(CVPixelBufferGetHeight(result.pixelBuffer) == 2)
        #expect(pixelBytes(in: result.pixelBuffer, x: 0, y: 0) == pixelBytes(in: source, x: 2, y: 1))
        #expect(pixelBytes(in: result.pixelBuffer, x: 2, y: 1) == pixelBytes(in: source, x: 4, y: 2))
    }

    @Test("Full-frame override returns original buffer")
    func fullFrameOverrideReturnsOriginalBuffer() throws {
        let source = try makeBGRAAtlas(width: 6, height: 4)
        let cropper = MiragePixelBufferCropper()

        let result = try #require(
            cropper.crop(source, to: CGRect(x: 0, y: 0, width: 6, height: 4))
        )

        #expect(result.usedOriginalBuffer)
        #expect(sameBuffer(result.pixelBuffer, source))
        #expect(CVPixelBufferGetWidth(result.pixelBuffer) == 6)
        #expect(CVPixelBufferGetHeight(result.pixelBuffer) == 4)
    }

    @Test("Out-of-bounds crop returns original buffer")
    func outOfBoundsCropReturnsOriginalBuffer() throws {
        let source = try makeBGRAAtlas(width: 6, height: 4)
        let cropper = MiragePixelBufferCropper()

        let result = try #require(
            cropper.crop(source, to: CGRect(x: 5, y: 0, width: 3, height: 2))
        )

        #expect(result.usedOriginalBuffer)
        #expect(sameBuffer(result.pixelBuffer, source))
        #expect(result.contentRect == CGRect(x: 0, y: 0, width: 6, height: 4))
    }

    private func makeBGRAAtlas(width: Int, height: Int) throws -> CVPixelBuffer {
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

    private func sameBuffer(_ lhs: CVPixelBuffer, _ rhs: CVPixelBuffer) -> Bool {
        Unmanaged.passUnretained(lhs).toOpaque() == Unmanaged.passUnretained(rhs).toOpaque()
    }
}
#endif
