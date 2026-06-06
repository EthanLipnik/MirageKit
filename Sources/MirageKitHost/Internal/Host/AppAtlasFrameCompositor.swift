//
//  AppAtlasFrameCompositor.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/3/26.
//

import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageKit
import MirageKitClientPresentation
import MirageMedia
import MirageWire
import CoreVideo
import Foundation
import Metal

#if os(macOS)
/// Errors emitted by the Metal app-atlas compositor.
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

/// Composes captured window frames into a single app-atlas pixel buffer with Metal.
final class AppAtlasFrameCompositor: @unchecked Sendable {
    /// Metal shader parameters for one source-to-destination copy.
    private struct CopyRegion {
        var sourceOriginX: UInt32
        var sourceOriginY: UInt32
        var sourceWidth: UInt32
        var sourceHeight: UInt32
        var destinationOriginX: UInt32
        var destinationOriginY: UInt32
        var width: UInt32
        var height: UInt32
        var destinationWidth: UInt32
        var destinationHeight: UInt32
    }

    /// Auxiliary frame and geometry composited over a parent window frame.
    struct OverlayFrame {
        /// Captured auxiliary window frame.
        let frame: CapturedFrame
        /// Source rectangle copied from the auxiliary frame.
        let sourceRect: CGRect
        /// Destination rectangle inside the parent output surface.
        let destinationRect: CGRect
    }

    /// Internal copy operation used for both atlas packing and parent overlay composition.
    private struct FrameCopyOperation {
        let frame: CapturedFrame
        let sourceRect: CGRect
        let destinationRect: CGRect
    }

    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLComputePipelineState
    private var textureCache: CVMetalTextureCache

    /// Creates the Metal pipeline and texture cache used by the compositor.
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

        self.commandQueue = commandQueue
        textureCache = cache
    }

    /// Composes each placed logical window frame into the atlas layout canvas.
    func compose(
        framesByWindowID: [WindowID: CapturedFrame],
        layout: AppAtlasLayout.Result
    ) throws -> CVPixelBuffer {
        let copyOperations = layout.placements.compactMap { placement -> FrameCopyOperation? in
            guard let frame = framesByWindowID[placement.id] else { return nil }
            return FrameCopyOperation(
                frame: frame,
                sourceRect: placement.sourceRect,
                destinationRect: placement.destinationRect
            )
        }
        return try compose(copyOperations: copyOperations, outputSize: layout.canvasSize)
    }

    /// Composes auxiliary overlays onto a parent frame-sized output surface.
    func compose(
        baseFrame: CapturedFrame,
        overlays: [OverlayFrame],
        outputSize: CGSize
    ) throws -> CVPixelBuffer {
        let baseSourceRect = CGRect(
            x: 0,
            y: 0,
            width: CVPixelBufferGetWidth(baseFrame.pixelBuffer),
            height: CVPixelBufferGetHeight(baseFrame.pixelBuffer)
        )
        let baseDestinationRect = CGRect(origin: .zero, size: outputSize)
        let copyOperations = [FrameCopyOperation(
            frame: baseFrame,
            sourceRect: baseSourceRect,
            destinationRect: baseDestinationRect
        )] + overlays.map { overlay in
            FrameCopyOperation(
                frame: overlay.frame,
                sourceRect: overlay.sourceRect,
                destinationRect: overlay.destinationRect
            )
        }
        return try compose(copyOperations: copyOperations, outputSize: outputSize)
    }

    /// Executes copy operations into a newly allocated BGRA pixel buffer.
    private func compose(
        copyOperations: [FrameCopyOperation],
        outputSize: CGSize
    ) throws -> CVPixelBuffer {
        let width = max(2, Int(outputSize.width.rounded(.up)))
        let height = max(2, Int(outputSize.height.rounded(.up)))
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

        for operation in copyOperations {
            let frame = operation.frame
            let pixelFormat = CVPixelBufferGetPixelFormatType(frame.pixelBuffer)
            guard pixelFormat == kCVPixelFormatType_32BGRA else {
                throw AppAtlasFrameCompositorError.unsupportedPixelFormat(pixelFormat)
            }

            let sourceWidth = CVPixelBufferGetWidth(frame.pixelBuffer)
            let sourceHeight = CVPixelBufferGetHeight(frame.pixelBuffer)
            let sourceRect = operation.sourceRect.integral
            let sourceOriginX = max(0, Int(sourceRect.minX))
            let sourceOriginY = max(0, Int(sourceRect.minY))
            let sourceCopyWidth = min(Int(sourceRect.width), max(0, sourceWidth - sourceOriginX))
            let sourceCopyHeight = min(Int(sourceRect.height), max(0, sourceHeight - sourceOriginY))
            let destinationRect = operation.destinationRect.integral
            let destinationOriginX = max(0, Int(destinationRect.minX))
            let destinationOriginY = max(0, Int(destinationRect.minY))
            let destinationWidth = max(0, Int(destinationRect.width))
            let destinationHeight = max(0, Int(destinationRect.height))
            let copyWidth = min(destinationWidth, max(0, width - destinationOriginX))
            let copyHeight = min(destinationHeight, max(0, height - destinationOriginY))
            guard sourceCopyWidth > 0,
                  sourceCopyHeight > 0,
                  destinationWidth > 0,
                  destinationHeight > 0,
                  copyWidth > 0,
                  copyHeight > 0 else { continue }

            let sourceTexture = try makeTexture(
                pixelBuffer: frame.pixelBuffer,
                pixelFormat: .bgra8Unorm,
                width: sourceWidth,
                height: sourceHeight
            )
            var region = CopyRegion(
                sourceOriginX: UInt32(sourceOriginX),
                sourceOriginY: UInt32(sourceOriginY),
                sourceWidth: UInt32(sourceCopyWidth),
                sourceHeight: UInt32(sourceCopyHeight),
                destinationOriginX: UInt32(destinationOriginX),
                destinationOriginY: UInt32(destinationOriginY),
                width: UInt32(copyWidth),
                height: UInt32(copyHeight),
                destinationWidth: UInt32(destinationWidth),
                destinationHeight: UInt32(destinationHeight)
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

    /// Allocates a Metal-compatible BGRA output pixel buffer.
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

    /// Clears a pixel buffer to transparent black before composition.
    private func clear(_ pixelBuffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) {
            memset(baseAddress, 0, CVPixelBufferGetDataSize(pixelBuffer))
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
    }

    /// Wraps a pixel buffer in a Metal texture.
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

    /// Builds the small compute library used for nearest-neighbor atlas copies.
    private static func makeLibrary(device: MTLDevice) throws -> MTLLibrary {
        let source = """
        #include <metal_stdlib>
        using namespace metal;

        struct CopyRegion {
            uint sourceOriginX;
            uint sourceOriginY;
            uint sourceWidth;
            uint sourceHeight;
            uint destinationOriginX;
            uint destinationOriginY;
            uint width;
            uint height;
            uint destinationWidth;
            uint destinationHeight;
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

            const uint sourceOffsetX = min(
                region.sourceWidth - 1,
                uint((float(gid.x) * float(region.sourceWidth)) / float(region.destinationWidth))
            );
            const uint sourceOffsetY = min(
                region.sourceHeight - 1,
                uint((float(gid.y) * float(region.sourceHeight)) / float(region.destinationHeight))
            );

            const uint2 sourceCoordinate(
                region.sourceOriginX + sourceOffsetX,
                region.sourceOriginY + sourceOffsetY
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
