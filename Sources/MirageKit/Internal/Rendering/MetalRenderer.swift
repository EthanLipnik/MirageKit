//
//  MetalRenderer.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/2/26.
//

import CoreVideo
import Foundation
import Metal
import MetalKit
import simd

/// Uniforms structure matching Metal shader (must be 16-byte aligned)
struct RenderUniforms {
    var contentRect: SIMD4<Float> // x, y, width, height (normalized 0-1)
    var colorMatrix: simd_float4x4
    var colorOffset: SIMD4<Float>
}

private struct ColorConversion {
    let matrix: simd_float4x4
    let offset: SIMD4<Float>
}

/// High-performance Metal renderer for decoded video frames
final class MetalRenderer {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState10: MTLRenderPipelineState
    private let pipelineState8: MTLRenderPipelineState
    private let pipelineState10YCbCr: MTLRenderPipelineState
    private let pipelineState8YCbCr: MTLRenderPipelineState
    private var textureCache: CVMetalTextureCache?
    private var uniformsBuffers: [MTLBuffer] = []
    private var uniformsBufferIndex: Int = 0
    private let uniformsBufferCount: Int = 3
    private var frameCount: UInt32 = 0
    private static let identityConversion = ColorConversion(
        matrix: matrix_identity_float4x4,
        offset: .zero
    )

    init(device: MTLDevice? = nil) throws {
        guard let mtlDevice = device ?? MTLCreateSystemDefaultDevice() else { throw MirageError.protocolError("Metal not available") }
        self.device = mtlDevice

        guard let queue = mtlDevice.makeCommandQueue() else { throw MirageError.protocolError("Failed to create command queue") }
        commandQueue = queue

        // Create texture cache for zero-copy CVPixelBuffer -> MTLTexture
        var cache: CVMetalTextureCache?
        let cacheStatus = CVMetalTextureCacheCreate(
            kCFAllocatorDefault,
            nil,
            mtlDevice,
            nil,
            &cache
        )

        if cacheStatus == kCVReturnSuccess { textureCache = cache }

        // Create a small ring of uniforms buffers to allow multiple in-flight draws.
        var buffers: [MTLBuffer] = []
        buffers.reserveCapacity(uniformsBufferCount)
        for _ in 0 ..< uniformsBufferCount {
            if let buffer = mtlDevice.makeBuffer(
                length: MemoryLayout<RenderUniforms>.stride,
                options: .storageModeShared
            ) {
                buffers.append(buffer)
            }
        }
        uniformsBuffers = buffers

        // Create render pipelines.
        let library = try Self.makeLibrary(device: mtlDevice)
        pipelineState10 = try Self.createPipeline(
            device: mtlDevice,
            library: library,
            fragmentFunctionName: "videoFragmentPlain",
            colorPixelFormat: .bgr10a2Unorm
        )
        pipelineState8 = try Self.createPipeline(
            device: mtlDevice,
            library: library,
            fragmentFunctionName: "videoFragmentPlain",
            colorPixelFormat: .bgra8Unorm
        )
        pipelineState10YCbCr = try Self.createPipeline(
            device: mtlDevice,
            library: library,
            fragmentFunctionName: "videoFragmentYCbCrPlain",
            colorPixelFormat: .bgr10a2Unorm
        )
        pipelineState8YCbCr = try Self.createPipeline(
            device: mtlDevice,
            library: library,
            fragmentFunctionName: "videoFragmentYCbCrPlain",
            colorPixelFormat: .bgra8Unorm
        )
    }

    private static func makeLibrary(device: MTLDevice) throws -> MTLLibrary {
        // Shader source with contentRect support.
        let shaderSource = """
        #include <metal_stdlib>
        using namespace metal;

        struct VertexOut {
            float4 position [[position]];
            float2 texCoord;
        };

        struct Uniforms {
            float4 contentRect;  // x, y, width, height (normalized 0-1)
            float4x4 colorMatrix;
            float4 colorOffset;
        };

        vertex VertexOut videoVertex(uint vertexID [[vertex_id]], constant Uniforms& uniforms [[buffer(0)]]) {
            float2 positions[4] = {
                float2(-1, -1),
                float2( 1, -1),
                float2(-1,  1),
                float2( 1,  1)
            };

            // Calculate UV coordinates based on contentRect
            // contentRect tells us where actual content is within the padded buffer
            float2 uvMin = uniforms.contentRect.xy;
            float2 uvSize = uniforms.contentRect.zw;

            // Map full screen quad to contentRect portion of texture
            // Bottom-left, bottom-right, top-left, top-right (Metal's triangle strip order)
            float2 texCoords[4] = {
                float2(uvMin.x, uvMin.y + uvSize.y),              // bottom-left
                float2(uvMin.x + uvSize.x, uvMin.y + uvSize.y),   // bottom-right
                float2(uvMin.x, uvMin.y),                          // top-left
                float2(uvMin.x + uvSize.x, uvMin.y)                // top-right
            };

            VertexOut out;
            out.position = float4(positions[vertexID], 0, 1);
            out.texCoord = texCoords[vertexID];
            return out;
        }

        float3 ycbcrToRgb(float y, float2 cbcr, constant Uniforms& uniforms) {
            float4 ycbcr = float4(y, cbcr, 1.0);
            ycbcr.xyz += uniforms.colorOffset.xyz;
            return (uniforms.colorMatrix * ycbcr).xyz;
        }

        fragment float4 videoFragmentPlain(
            VertexOut in [[stage_in]],
            texture2d<float> colorTexture [[texture(0)]]
        ) {
            constexpr sampler textureSampler(mag_filter::linear, min_filter::linear);
            return colorTexture.sample(textureSampler, in.texCoord);
        }

        fragment float4 videoFragmentYCbCrPlain(
            VertexOut in [[stage_in]],
            texture2d<float> lumaTexture [[texture(0)]],
            texture2d<float> chromaTexture [[texture(1)]],
            constant Uniforms& uniforms [[buffer(0)]]
        ) {
            constexpr sampler textureSampler(mag_filter::linear, min_filter::linear);
            float y = lumaTexture.sample(textureSampler, in.texCoord).r;
            float2 cbcr = chromaTexture.sample(textureSampler, in.texCoord).rg;
            float3 rgb = ycbcrToRgb(y, cbcr, uniforms);
            return float4(rgb, 1.0);
        }
        """

        return try device.makeLibrary(source: shaderSource, options: nil)
    }

    private static func createPipeline(
        device: MTLDevice,
        library: MTLLibrary,
        fragmentFunctionName: String,
        colorPixelFormat: MTLPixelFormat
    )
    throws -> MTLRenderPipelineState {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "videoVertex")
        descriptor.fragmentFunction = library.makeFunction(name: fragmentFunctionName)
        descriptor.colorAttachments[0].pixelFormat = colorPixelFormat

        return try device.makeRenderPipelineState(descriptor: descriptor)
    }

    /// Create a Metal texture from a CVPixelBuffer (zero-copy via IOSurface)
    func createTexture(from pixelBuffer: CVPixelBuffer) -> MTLTexture? {
        guard let cache = textureCache else { return nil }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let pixelFormatType = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let metalPixelFormat: MTLPixelFormat = switch pixelFormatType {
        case kCVPixelFormatType_32BGRA:
            .bgra8Unorm
        case kCVPixelFormatType_ARGB2101010LEPacked:
            .bgr10a2Unorm
        default:
            .bgr10a2Unorm
        }

        var metalTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            cache,
            pixelBuffer,
            nil,
            metalPixelFormat,
            width,
            height,
            0,
            &metalTexture
        )

        guard status == kCVReturnSuccess, let metalTexture else { return nil }

        return CVMetalTextureGetTexture(metalTexture)
    }

    private func createYCbCrTextures(from pixelBuffer: CVPixelBuffer) -> (luma: MTLTexture, chroma: MTLTexture)? {
        guard let cache = textureCache else { return nil }
        guard CVPixelBufferGetPlaneCount(pixelBuffer) >= 2 else { return nil }

        let pixelFormatType = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let lumaFormat: MTLPixelFormat
        let chromaFormat: MTLPixelFormat
        switch pixelFormatType {
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
             kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            lumaFormat = .r8Unorm
            chromaFormat = .rg8Unorm
        case kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
             kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange:
            lumaFormat = .r16Unorm
            chromaFormat = .rg16Unorm
        default:
            return nil
        }

        let lumaWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let lumaHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let chromaWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, 1)
        let chromaHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1)

        var lumaTexture: CVMetalTexture?
        let lumaStatus = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            cache,
            pixelBuffer,
            nil,
            lumaFormat,
            lumaWidth,
            lumaHeight,
            0,
            &lumaTexture
        )

        var chromaTexture: CVMetalTexture?
        let chromaStatus = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            cache,
            pixelBuffer,
            nil,
            chromaFormat,
            chromaWidth,
            chromaHeight,
            1,
            &chromaTexture
        )

        guard lumaStatus == kCVReturnSuccess,
              chromaStatus == kCVReturnSuccess,
              let lumaTexture,
              let chromaTexture,
              let lumaMTL = CVMetalTextureGetTexture(lumaTexture),
              let chromaMTL = CVMetalTextureGetTexture(chromaTexture) else {
            return nil
        }

        return (lumaMTL, chromaMTL)
    }

    private func colorConversion(for pixelBuffer: CVPixelBuffer) -> ColorConversion {
        let matrixKey = CVBufferCopyAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey, nil) as? String
        let baseMatrix = ycbcrMatrix(for: matrixKey)
        let isFullRange = isFullRange(pixelBuffer: pixelBuffer)

        let yScale: Float
        let cScale: Float
        let yOffset: Float
        let cOffset: Float
        if isFullRange {
            yScale = 1.0
            cScale = 1.0
            yOffset = 0.0
            cOffset = 0.5
        } else {
            yScale = 255.0 / 219.0
            cScale = 255.0 / 224.0
            yOffset = 16.0 / 255.0
            cOffset = 128.0 / 255.0
        }

        let scaledMatrix = simd_float3x3(columns: (
            baseMatrix.columns.0 * yScale,
            baseMatrix.columns.1 * cScale,
            baseMatrix.columns.2 * cScale
        ))
        let matrix = simd_float4x4(columns: (
            SIMD4<Float>(scaledMatrix.columns.0, 0),
            SIMD4<Float>(scaledMatrix.columns.1, 0),
            SIMD4<Float>(scaledMatrix.columns.2, 0),
            SIMD4<Float>(0, 0, 0, 1)
        ))
        let offset = SIMD4<Float>(-yOffset, -cOffset, -cOffset, 0)
        return ColorConversion(matrix: matrix, offset: offset)
    }

    private func ycbcrMatrix(for matrixKey: String?) -> simd_float3x3 {
        if matrixKey == (kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String) {
            return simd_float3x3(columns: (
                SIMD3<Float>(1.0, 1.0, 1.0),
                SIMD3<Float>(0.0, -0.344136, 1.772),
                SIMD3<Float>(1.402, -0.714136, 0.0)
            ))
        }
        if matrixKey == (kCVImageBufferYCbCrMatrix_ITU_R_2020 as String) {
            return simd_float3x3(columns: (
                SIMD3<Float>(1.0, 1.0, 1.0),
                SIMD3<Float>(0.0, -0.164553, 1.8814),
                SIMD3<Float>(1.4746, -0.571353, 0.0)
            ))
        }

        return simd_float3x3(columns: (
            SIMD3<Float>(1.0, 1.0, 1.0),
            SIMD3<Float>(0.0, -0.187324, 1.8556),
            SIMD3<Float>(1.5748, -0.468124, 0.0)
        ))
    }

    private func isFullRange(pixelBuffer: CVPixelBuffer) -> Bool {
        let pixelFormatType = CVPixelBufferGetPixelFormatType(pixelBuffer)
        switch pixelFormatType {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange:
            return false
        default:
            return true
        }
    }

    private func nextUniformsBuffer() -> MTLBuffer? {
        guard !uniformsBuffers.isEmpty else { return nil }
        let buffer = uniformsBuffers[uniformsBufferIndex]
        uniformsBufferIndex = (uniformsBufferIndex + 1) % uniformsBuffers.count
        return buffer
    }

    /// Render a texture to a drawable with optional contentRect for cropping SCK black bars
    /// - Parameters:
    ///   - textures: The source textures to render (RGB or Y/CbCr).
    ///   - pipelineState: Pipeline state to use for this render.
    ///   - drawable: The drawable to render to.
    ///   - contentRect: The region containing actual content (in pixels). If nil or empty, uses full texture.
    ///   - colorConversion: Matrix and offsets for YCbCr conversion (identity for RGB).
    ///   - completion: Callback invoked after the command buffer completes (or immediately on failure).
    private func render(
        textures: [MTLTexture],
        pipelineState: MTLRenderPipelineState,
        to drawable: CAMetalDrawable,
        contentRect: CGRect? = nil,
        colorConversion: ColorConversion,
        completion: (@Sendable () -> Void)? = nil
    ) {
        let signpostState = MirageSignpost.beginInterval("Render")
        defer { MirageSignpost.endInterval("Render", signpostState) }

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            if let completion {
                Task { @MainActor in completion() }
            }
            return
        }

        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = drawable.texture
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].storeAction = .store
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            if let completion {
                Task { @MainActor in completion() }
            }
            return
        }

        encoder.setRenderPipelineState(pipelineState)
        for (index, texture) in textures.enumerated() {
            encoder.setFragmentTexture(texture, index: index)
        }

        let primaryTexture = textures[0]
        let textureWidth = Float(primaryTexture.width)
        let textureHeight = Float(primaryTexture.height)

        let normalizedRect: SIMD4<Float>
        if let rect = contentRect, !rect.isEmpty {
            normalizedRect = SIMD4<Float>(
                Float(rect.origin.x) / textureWidth,
                Float(rect.origin.y) / textureHeight,
                Float(rect.width) / textureWidth,
                Float(rect.height) / textureHeight
            )

            if frameCount % 120 == 1 {
                MirageLogger
                    .renderer(
                        "contentRect: \(rect) -> normalized: (\(normalizedRect.x), \(normalizedRect.y), \(normalizedRect.z), \(normalizedRect.w)) texture: \(Int(textureWidth))x\(Int(textureHeight))"
                    )
            }
        } else {
            normalizedRect = SIMD4<Float>(0, 0, 1, 1)
        }

        frameCount = frameCount &+ 1
        var uniforms = RenderUniforms(
            contentRect: normalizedRect,
            colorMatrix: colorConversion.matrix,
            colorOffset: colorConversion.offset
        )
        guard let uniformsBuffer = nextUniformsBuffer() else {
            encoder.endEncoding()
            if let completion {
                Task { @MainActor in completion() }
            }
            return
        }
        uniformsBuffer.contents().copyMemory(from: &uniforms, byteCount: MemoryLayout<RenderUniforms>.size)

        encoder.setVertexBuffer(uniformsBuffer, offset: 0, index: 0)
        encoder.setFragmentBuffer(uniformsBuffer, offset: 0, index: 0)

        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        let shouldLogRender = MirageLogger.isEnabled(.renderer) && frameCount % 120 == 0
        if shouldLogRender {
            commandBuffer.addCompletedHandler { buffer in
                let gpuMs = (buffer.gpuEndTime - buffer.gpuStartTime) * 1000
                if gpuMs > 0 {
                    let gpuText = gpuMs.formatted(.number.precision(.fractionLength(1)))
                    MirageLogger.renderer("Render GPU: \(gpuText)ms")
                }
            }
        }

        commandBuffer.present(drawable)
        if let completion {
            // @unchecked Sendable: guarded by NSLock and only fires onto the main queue.
            final class CompletionOnce: @unchecked Sendable {
                private let lock = NSLock()
                private var fired = false
                private let completion: () -> Void

                init(_ completion: @escaping () -> Void) {
                    self.completion = completion
                }

                func fire() {
                    lock.lock()
                    let shouldFire = !fired
                    if shouldFire { fired = true }
                    lock.unlock()
                    guard shouldFire else { return }
                    DispatchQueue.main.async { self.completion() }
                }
            }

            let completionOnce = CompletionOnce(completion)
            #if os(macOS)
            // Prefer presentation timing so scheduler release tracks drawable availability.
            drawable.addPresentedHandler { _ in completionOnce.fire() }
            // Fall back to GPU completion if presentation callbacks are delayed or skipped.
            commandBuffer.addCompletedHandler { _ in completionOnce.fire() }
            #else
            // iOS/visionOS: use GPU completion timing (addPresentedHandler not available).
            commandBuffer.addCompletedHandler { _ in completionOnce.fire() }
            #endif
        }
        commandBuffer.commit()
    }

    /// Render a pixel buffer directly to a drawable
    func render(
        pixelBuffer: CVPixelBuffer,
        to drawable: CAMetalDrawable,
        contentRect: CGRect? = nil,
        outputPixelFormat: MTLPixelFormat = .bgr10a2Unorm,
        completion: (@Sendable () -> Void)? = nil
    ) {
        if let ycbcrTextures = createYCbCrTextures(from: pixelBuffer) {
            let conversion = colorConversion(for: pixelBuffer)
            let pipelineState = pipelineState(for: outputPixelFormat, usesYCbCr: true)

            if frameCount % 120 == 0 {
                let drawableW = drawable.texture.width
                let drawableH = drawable.texture.height
                let textureW = ycbcrTextures.luma.width
                let textureH = ycbcrTextures.luma.height
                if drawableW != textureW || drawableH != textureH {
                    MirageLogger
                        .renderer(
                            "Dimension mismatch - Drawable: \(drawableW)x\(drawableH), Texture: \(textureW)x\(textureH)"
                        )
                }
                if let rect = contentRect, !rect.isEmpty { MirageLogger.renderer("contentRect: \(rect) (texture: \(textureW)x\(textureH))") }
            }

            render(
                textures: [ycbcrTextures.luma, ycbcrTextures.chroma],
                pipelineState: pipelineState,
                to: drawable,
                contentRect: contentRect,
                colorConversion: conversion,
                completion: completion
            )
            return
        }

        guard let texture = createTexture(from: pixelBuffer) else {
            if let completion {
                Task { @MainActor in completion() }
            }
            return
        }

        if frameCount % 120 == 0 {
            let drawableW = drawable.texture.width
            let drawableH = drawable.texture.height
            let textureW = texture.width
            let textureH = texture.height
            if drawableW != textureW || drawableH != textureH {
                MirageLogger
                    .renderer(
                        "Dimension mismatch - Drawable: \(drawableW)x\(drawableH), Texture: \(textureW)x\(textureH)"
                    )
            }
            if let rect = contentRect, !rect.isEmpty { MirageLogger.renderer("contentRect: \(rect) (texture: \(textureW)x\(textureH))") }
        }

        render(
            textures: [texture],
            pipelineState: pipelineState(for: outputPixelFormat, usesYCbCr: false),
            to: drawable,
            contentRect: contentRect,
            colorConversion: Self.identityConversion,
            completion: completion
        )
    }

    /// Flush the texture cache
    func flushCache() {
        if let cache = textureCache { CVMetalTextureCacheFlush(cache, 0) }
    }

    private func pipelineState(for outputPixelFormat: MTLPixelFormat, usesYCbCr: Bool) -> MTLRenderPipelineState {
        switch (outputPixelFormat, usesYCbCr) {
        case (.bgra8Unorm, true):
            return pipelineState8YCbCr
        case (.bgra8Unorm, false):
            return pipelineState8
        case (_, true):
            return pipelineState10YCbCr
        default:
            return pipelineState10
        }
    }
}
