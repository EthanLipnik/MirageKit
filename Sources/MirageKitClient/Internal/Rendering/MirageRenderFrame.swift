//
//  MirageRenderFrame.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/16/26.
//
//  Stream-local frame snapshot for decode-to-render handoff.
//

import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import Metal
import MirageKit

struct MirageRenderFrame: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let contentRect: CGRect
    let sequence: UInt64
    let decodeTime: CFAbsoluteTime
    let presentationTime: CMTime
    let metalTexture: CVMetalTexture?
    let texture: MTLTexture?
    let approximateByteSize: Int

    static func estimatedByteSize(for pixelBuffer: CVPixelBuffer) -> Int {
        let directDataSize = CVPixelBufferGetDataSize(pixelBuffer)
        if directDataSize > 0 {
            return directDataSize
        }

        let planeCount = CVPixelBufferGetPlaneCount(pixelBuffer)
        if planeCount > 0 {
            var totalBytes = 0
            for plane in 0 ..< planeCount {
                totalBytes += CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane) *
                    CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)
            }
            if totalBytes > 0 {
                return totalBytes
            }
        }

        let fallbackBytes = CVPixelBufferGetBytesPerRow(pixelBuffer) * CVPixelBufferGetHeight(pixelBuffer)
        return max(1, fallbackBytes)
    }
}
