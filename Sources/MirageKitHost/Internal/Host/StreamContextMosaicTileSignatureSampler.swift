//
//  StreamContextMosaicTileSignatureSampler.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 6/7/26.
//

import CoreVideo
import Foundation
import MirageMedia

#if os(macOS)

enum StreamContextMosaicTileSignatureSampler {
    private static let fnvOffset: UInt64 = 14_695_981_039_346_656_037
    private static let fnvPrime: UInt64 = 1_099_511_628_211
    private static let samplesPerAxis = 4

    static func signatures(
        in pixelBuffer: CVPixelBuffer,
        for plan: MirageMosaicTilePlan
    ) -> [MirageMosaicTileID: MirageMosaicTileSignature] {
        guard !plan.tiles.isEmpty else { return [:] }
        let status = CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        guard status == kCVReturnSuccess else { return [:] }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        var signatures: [MirageMosaicTileID: MirageMosaicTileSignature] = [:]
        signatures.reserveCapacity(plan.tiles.count)
        for tile in plan.tiles {
            guard let signature = signature(in: pixelBuffer, pixelFormat: pixelFormat, rect: tile.sourceRect) else {
                return [:]
            }
            signatures[tile.id] = signature
        }
        return signatures
    }

    private static func signature(
        in pixelBuffer: CVPixelBuffer,
        pixelFormat: OSType,
        rect: MiragePixelRect
    ) -> MirageMosaicTileSignature? {
        switch pixelFormat {
        case kCVPixelFormatType_32BGRA:
            return packed32Signature(in: pixelBuffer, rect: rect)
        case kCVPixelFormatType_ARGB2101010LEPacked:
            return packed32RawSignature(in: pixelBuffer, rect: rect)
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
             kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            return biPlanar8Signature(in: pixelBuffer, rect: rect, chromaScaleX: 2, chromaScaleY: 2)
        case kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
             kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange:
            return biPlanar16Signature(in: pixelBuffer, rect: rect, chromaScaleX: 2, chromaScaleY: 2)
        case kCVPixelFormatType_444YpCbCr10BiPlanarFullRange:
            return biPlanar16Signature(in: pixelBuffer, rect: rect, chromaScaleX: 1, chromaScaleY: 1)
        default:
            return nil
        }
    }

    private static func packed32Signature(
        in pixelBuffer: CVPixelBuffer,
        rect: MiragePixelRect
    ) -> MirageMosaicTileSignature? {
        guard CVPixelBufferGetPlaneCount(pixelBuffer) == 0,
              let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return nil
        }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard let sampleRect = clipped(rect, width: width, height: height) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        return sample(sampleRect) { x, y, lumaHash, chromaHash in
            let row = baseAddress.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            let offset = x * 4
            let blue = UInt32(row[offset])
            let green = UInt32(row[offset + 1])
            let red = UInt32(row[offset + 2])
            let luma = (77 * red + 150 * green + 29 * blue) >> 8
            mix(&lumaHash, luma)
            mix(&chromaHash, (red << 16) | (green << 8) | blue)
        }
    }

    private static func packed32RawSignature(
        in pixelBuffer: CVPixelBuffer,
        rect: MiragePixelRect
    ) -> MirageMosaicTileSignature? {
        guard CVPixelBufferGetPlaneCount(pixelBuffer) == 0,
              let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return nil
        }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard let sampleRect = clipped(rect, width: width, height: height) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        return sample(sampleRect) { x, y, lumaHash, chromaHash in
            let row = baseAddress.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            let offset = x * 4
            let value = UInt32(row[offset]) |
                UInt32(row[offset + 1]) << 8 |
                UInt32(row[offset + 2]) << 16 |
                UInt32(row[offset + 3]) << 24
            mix(&lumaHash, value)
            mix(&chromaHash, value >> 10)
        }
    }

    private static func biPlanar8Signature(
        in pixelBuffer: CVPixelBuffer,
        rect: MiragePixelRect,
        chromaScaleX: Int,
        chromaScaleY: Int
    ) -> MirageMosaicTileSignature? {
        guard CVPixelBufferGetPlaneCount(pixelBuffer) >= 2,
              let yBaseAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
              let uvBaseAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) else {
            return nil
        }
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let chromaWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, 1)
        let chromaHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1)
        guard let sampleRect = clipped(rect, width: width, height: height),
              chromaWidth > 0, chromaHeight > 0 else {
            return nil
        }
        let yBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let uvBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
        return sample(sampleRect) { x, y, lumaHash, chromaHash in
            let yRow = yBaseAddress.advanced(by: y * yBytesPerRow).assumingMemoryBound(to: UInt8.self)
            let uvX = min(chromaWidth - 1, x / chromaScaleX)
            let uvY = min(chromaHeight - 1, y / chromaScaleY)
            let uvRow = uvBaseAddress.advanced(by: uvY * uvBytesPerRow).assumingMemoryBound(to: UInt8.self)
            let uvOffset = uvX * 2
            mix(&lumaHash, UInt32(yRow[x]))
            mix(&chromaHash, UInt32(uvRow[uvOffset]) << 8 | UInt32(uvRow[uvOffset + 1]))
        }
    }

    private static func biPlanar16Signature(
        in pixelBuffer: CVPixelBuffer,
        rect: MiragePixelRect,
        chromaScaleX: Int,
        chromaScaleY: Int
    ) -> MirageMosaicTileSignature? {
        guard CVPixelBufferGetPlaneCount(pixelBuffer) >= 2,
              let yBaseAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
              let uvBaseAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) else {
            return nil
        }
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let chromaWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, 1)
        let chromaHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1)
        guard let sampleRect = clipped(rect, width: width, height: height),
              chromaWidth > 0, chromaHeight > 0 else {
            return nil
        }
        let yBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let uvBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
        return sample(sampleRect) { x, y, lumaHash, chromaHash in
            let yRow = yBaseAddress.advanced(by: y * yBytesPerRow).assumingMemoryBound(to: UInt8.self)
            let uvX = min(chromaWidth - 1, x / chromaScaleX)
            let uvY = min(chromaHeight - 1, y / chromaScaleY)
            let uvRow = uvBaseAddress.advanced(by: uvY * uvBytesPerRow).assumingMemoryBound(to: UInt8.self)
            let luma = littleEndianUInt16(yRow, offset: x * 2)
            let u = littleEndianUInt16(uvRow, offset: uvX * 4)
            let v = littleEndianUInt16(uvRow, offset: uvX * 4 + 2)
            mix(&lumaHash, UInt32(luma))
            mix(&chromaHash, UInt32(u) << 16 | UInt32(v))
        }
    }

    private static func sample(
        _ rect: MiragePixelRect,
        visit: (_ x: Int, _ y: Int, _ lumaHash: inout UInt64, _ chromaHash: inout UInt64) -> Void
    ) -> MirageMosaicTileSignature {
        let xSamples = min(samplesPerAxis, max(1, rect.width))
        let ySamples = min(samplesPerAxis, max(1, rect.height))
        var lumaHash = fnvOffset
        var chromaHash = fnvOffset
        var sampleCount = 0
        for yIndex in 0 ..< ySamples {
            let y = rect.y + ((yIndex * 2 + 1) * rect.height) / (ySamples * 2)
            for xIndex in 0 ..< xSamples {
                let x = rect.x + ((xIndex * 2 + 1) * rect.width) / (xSamples * 2)
                visit(x, y, &lumaHash, &chromaHash)
                sampleCount += 1
            }
        }
        return MirageMosaicTileSignature(
            lumaHash: lumaHash,
            chromaHash: chromaHash,
            sampleCount: sampleCount
        )
    }

    private static func clipped(_ rect: MiragePixelRect, width: Int, height: Int) -> MiragePixelRect? {
        guard width > 0, height > 0 else { return nil }
        let minX = min(max(0, rect.x), width)
        let minY = min(max(0, rect.y), height)
        let maxX = min(max(minX, rect.x + rect.width), width)
        let maxY = min(max(minY, rect.y + rect.height), height)
        guard maxX > minX, maxY > minY else { return nil }
        return MiragePixelRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private static func littleEndianUInt16(_ row: UnsafePointer<UInt8>, offset: Int) -> UInt16 {
        UInt16(row[offset]) | UInt16(row[offset + 1]) << 8
    }

    private static func mix(_ hash: inout UInt64, _ value: UInt32) {
        hash ^= UInt64(value)
        hash = hash &* fnvPrime
    }
}

#endif
