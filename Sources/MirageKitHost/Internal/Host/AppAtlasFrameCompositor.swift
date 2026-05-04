//
//  AppAtlasFrameCompositor.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/3/26.
//

import CoreVideo
import Foundation
import Metal
import MirageKit

#if os(macOS)
enum AppAtlasFrameCompositorError: Error, LocalizedError {
    case metalUnavailable
    case unsupportedPixelFormat(OSType)
    case outputAllocationFailed(OSStatus)
    case textureCreationFailed(OSStatus)
    case commandBufferUnavailable
    case encoderUnavailable
    case compositionFailed

    var errorDescription: String? {
        switch self {
        case .metalUnavailable:
            "Metal is unavailable for app-atlas composition."
        case let .unsupportedPixelFormat(pixelFormat):
            "Unsupported app-atlas pixel format \(pixelFormat)."
        case let .outputAllocationFailed(status):
            "Failed to allocate app-atlas output buffer (\(status))."
        case let .textureCreationFailed(status):
            "Failed to create app-atlas Metal texture (\(status))."
        case .commandBufferUnavailable:
            "Failed to create app-atlas command buffer."
        case .encoderUnavailable:
            "Failed to create app-atlas command encoder."
        case .compositionFailed:
            "App-atlas Metal composition failed."
        }
    }
}

final class AppAtlasFrameCompositor: @unchecked Sendable {
    private struct CopyRegion {
        var sourceOriginX: UInt32
        var sourceOriginY: UInt32
        var destinationOriginX: UInt32
        var destinationOriginY: UInt32
        var width: UInt32
        var height: UInt32
    }

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLComputePipelineState
    private var textureCache: CVMetalTextureCache

    init(device: MTLDevice? = MTLCreateSystemDefaultDevice()) throws {
        guard let device,
              let commandQueue = device.makeCommandQueue() else {
            throw AppAtlasFrameCompositorError.metalUnavailable
        }

        let library = try Self.makeLibrary(device: device)
        guard let function = library.makeFunction(name: "copyAppAtlasRegion") else {
            throw AppAtlasFrameCompositorError.metalUnavailable
        }
        pipelineState = try device.makeComputePipelineState(function: function)

        var cache: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        guard status == kCVReturnSuccess, let cache else {
            throw AppAtlasFrameCompositorError.textureCreationFailed(status)
        }

        self.device = device
        self.commandQueue = commandQueue
        textureCache = cache
    }

    func compose(
        framesByWindowID: [WindowID: CapturedFrame],
        layout: AppAtlasLayout.Result
    ) throws -> CVPixelBuffer {
        let width = max(2, Int(layout.canvasSize.width))
        let height = max(2, Int(layout.canvasSize.height))
        let outputBuffer = try makeOutputBuffer(width: width, height: height)
        clear(outputBuffer)

        let outputTexture = try makeTexture(
            pixelBuffer: outputBuffer,
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height
        )

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw AppAtlasFrameCompositorError.commandBufferUnavailable
        }

        for placement in layout.placements {
            guard let frame = framesByWindowID[placement.windowID] else { continue }
            let pixelFormat = CVPixelBufferGetPixelFormatType(frame.pixelBuffer)
            guard pixelFormat == kCVPixelFormatType_32BGRA else {
                throw AppAtlasFrameCompositorError.unsupportedPixelFormat(pixelFormat)
            }

            let sourceWidth = CVPixelBufferGetWidth(frame.pixelBuffer)
            let sourceHeight = CVPixelBufferGetHeight(frame.pixelBuffer)
            let sourceRect = placement.sourceRect.integral
            let sourceOriginX = max(0, Int(sourceRect.minX))
            let sourceOriginY = max(0, Int(sourceRect.minY))
            let destinationOriginX = max(0, Int(placement.destinationRect.minX))
            let destinationOriginY = max(0, Int(placement.destinationRect.minY))
            let copyWidth = [
                Int(placement.destinationRect.width),
                Int(sourceRect.width),
                max(0, sourceWidth - sourceOriginX),
                max(0, width - destinationOriginX),
            ].min() ?? 0
            let copyHeight = [
                Int(placement.destinationRect.height),
                Int(sourceRect.height),
                max(0, sourceHeight - sourceOriginY),
                max(0, height - destinationOriginY),
            ].min() ?? 0
            guard copyWidth > 0, copyHeight > 0 else { continue }

            let sourceTexture = try makeTexture(
                pixelBuffer: frame.pixelBuffer,
                pixelFormat: .bgra8Unorm,
                width: sourceWidth,
                height: sourceHeight
            )
            var region = CopyRegion(
                sourceOriginX: UInt32(sourceOriginX),
                sourceOriginY: UInt32(sourceOriginY),
                destinationOriginX: UInt32(destinationOriginX),
                destinationOriginY: UInt32(destinationOriginY),
                width: UInt32(copyWidth),
                height: UInt32(copyHeight)
            )

            guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
                throw AppAtlasFrameCompositorError.encoderUnavailable
            }
            encoder.setComputePipelineState(pipelineState)
            encoder.setTexture(sourceTexture, index: 0)
            encoder.setTexture(outputTexture, index: 1)
            encoder.setBytes(&region, length: MemoryLayout<CopyRegion>.stride, index: 0)

            let threadWidth = min(pipelineState.threadExecutionWidth, 16)
            let threadHeight = max(1, min(16, pipelineState.maxTotalThreadsPerThreadgroup / max(1, threadWidth)))
            let threadsPerGroup = MTLSize(width: threadWidth, height: threadHeight, depth: 1)
            let threadgroups = MTLSize(
                width: (copyWidth + threadWidth - 1) / threadWidth,
                height: (copyHeight + threadHeight - 1) / threadHeight,
                depth: 1
            )
            encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadsPerGroup)
            encoder.endEncoding()
        }

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        if let error = commandBuffer.error {
            MirageLogger.error(.host, error: error, message: "App-atlas composition failed: ")
            throw AppAtlasFrameCompositorError.compositionFailed
        }

        return outputBuffer
    }

    private func makeOutputBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:],
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
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw AppAtlasFrameCompositorError.outputAllocationFailed(status)
        }
        return pixelBuffer
    }

    private func clear(_ pixelBuffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) {
            memset(baseAddress, 0, CVPixelBufferGetDataSize(pixelBuffer))
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
    }

    private func makeTexture(
        pixelBuffer: CVPixelBuffer,
        pixelFormat: MTLPixelFormat,
        width: Int,
        height: Int
    ) throws -> MTLTexture {
        var textureRef: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            pixelFormat,
            width,
            height,
            0,
            &textureRef
        )
        guard status == kCVReturnSuccess,
              let textureRef,
              let texture = CVMetalTextureGetTexture(textureRef) else {
            throw AppAtlasFrameCompositorError.textureCreationFailed(status)
        }
        return texture
    }

    private static func makeLibrary(device: MTLDevice) throws -> MTLLibrary {
        let source = """
        #include <metal_stdlib>
        using namespace metal;

        struct CopyRegion {
            uint sourceOriginX;
            uint sourceOriginY;
            uint destinationOriginX;
            uint destinationOriginY;
            uint width;
            uint height;
        };

        kernel void copyAppAtlasRegion(
            texture2d<float, access::read> source [[texture(0)]],
            texture2d<float, access::write> destination [[texture(1)]],
            constant CopyRegion& region [[buffer(0)]],
            uint2 gid [[thread_position_in_grid]]
        ) {
            if (gid.x >= region.width || gid.y >= region.height) {
                return;
            }

            const uint2 sourceCoordinate(
                region.sourceOriginX + gid.x,
                region.sourceOriginY + gid.y
            );
            const uint2 destinationCoordinate(
                region.destinationOriginX + gid.x,
                region.destinationOriginY + gid.y
            );

            if (sourceCoordinate.x >= source.get_width() ||
                sourceCoordinate.y >= source.get_height() ||
                destinationCoordinate.x >= destination.get_width() ||
                destinationCoordinate.y >= destination.get_height()) {
                return;
            }

            destination.write(source.read(sourceCoordinate), destinationCoordinate);
        }
        """
        return try device.makeLibrary(source: source, options: nil)
    }
}
#endif
