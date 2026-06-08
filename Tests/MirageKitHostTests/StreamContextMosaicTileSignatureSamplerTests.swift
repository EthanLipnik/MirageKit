//
//  StreamContextMosaicTileSignatureSamplerTests.swift
//  MirageKitHost
//
//  Created by Ethan Lipnik on 6/7/26.
//

#if os(macOS)
@testable import MirageKitHost
import CoreVideo
import MirageMedia
import Testing

@Suite("StreamContext Mosaic Tile Signature Sampler")
struct StreamContextMosaicTileSignatureSamplerTests {
    @Test("BGRA signatures isolate changed tile")
    func bgraSignaturesIsolateChangedTile() throws {
        let plan = MirageMosaicTilePlan.fixedGrid(
            logicalSize: MiragePixelSize(width: 12, height: 12),
            columns: 3,
            rows: 3,
            codec: .hevc
        )
        let buffer = try makeBGRA(width: 12, height: 12)
        let initial = StreamContextMosaicTileSignatureSampler.signatures(in: buffer, for: plan)

        let changedTileID = MirageMosaicTileID(rawValue: "grid-4")
        let changedTile = try #require(plan.tile(for: changedTileID))
        fillBGRA(buffer, rect: changedTile.sourceRect, blue: 0, green: 0, red: 255)
        let changed = StreamContextMosaicTileSignatureSampler.signatures(in: buffer, for: plan)

        let changedTileIDs = Set(changed.compactMap { tileID, signature -> MirageMosaicTileID? in
            initial[tileID] == signature ? nil : tileID
        })
        #expect(initial.count == 9)
        #expect(changed.count == 9)
        #expect(changedTileIDs == [changedTileID])
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
        fillBGRA(
            buffer,
            rect: MiragePixelRect(x: 0, y: 0, width: width, height: height),
            blue: 24,
            green: 32,
            red: 40
        )
        return buffer
    }

    private func fillBGRA(
        _ buffer: CVPixelBuffer,
        rect: MiragePixelRect,
        blue: UInt8,
        green: UInt8,
        red: UInt8
    ) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(buffer) else { return }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let maxX = min(CVPixelBufferGetWidth(buffer), rect.x + rect.width)
        let maxY = min(CVPixelBufferGetHeight(buffer), rect.y + rect.height)
        for y in rect.y ..< maxY {
            let row = baseAddress
                .advanced(by: y * bytesPerRow)
                .assumingMemoryBound(to: UInt8.self)
            for x in rect.x ..< maxX {
                let offset = x * 4
                row[offset] = blue
                row[offset + 1] = green
                row[offset + 2] = red
                row[offset + 3] = 255
            }
        }
    }
}
#endif
