//
//  MetalRenderer.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/2/26.
//

import Foundation
import Metal
import MetalKit
import CoreVideo

/// Uniforms structure matching Metal shader (must be 16-byte aligned)
struct RenderUniforms {
    var frameCount: UInt32
    var padding: UInt32 = 0  // Padding for alignment
    var padding2: UInt32 = 0
    var padding3: UInt32 = 0
    var contentRect: SIMD4<Float>  // x, y, width, height (normalized 0-1)
}

/// High-performance Metal renderer for decoded video frames
final class MetalRenderer {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineStateDither: MTLRenderPipelineState
    private let pipelineStateNoDither: MTLRenderPipelineState
    private var textureCache: CVMetalTextureCache?
    private var uniformsBuffer: MTLBuffer?
    private var frameCount: UInt32 = 0
    private var temporalDitheringEnabled: Bool = true

    init(device: MTLDevice? = nil) throws {
        guard let mtlDevice = device ?? MTLCreateSystemDefaultDevice() else {
            throw MirageError.protocolError("Metal not available")
        }
        self.device = mtlDevice

        guard let queue = mtlDevice.makeCommandQueue() else {
            throw MirageError.protocolError("Failed to create command queue")
        }
        self.commandQueue = queue

        // Create texture cache for zero-copy CVPixelBuffer -> MTLTexture
        var cache: CVMetalTextureCache?
        let cacheStatus = CVMetalTextureCacheCreate(
            kCFAllocatorDefault,
            nil,
            mtlDevice,
            nil,
            &cache
        )

        if cacheStatus == kCVReturnSuccess {
            textureCache = cache
        }

        // Create uniforms buffer for contentRect and optional dithering
        self.uniformsBuffer = mtlDevice.makeBuffer(length: MemoryLayout<RenderUniforms>.size, options: .storageModeShared)

        // Create render pipelines (dithered and non-dithered)
        let library = try Self.makeLibrary(device: mtlDevice)
        pipelineStateDither = try Self.createPipeline(
            device: mtlDevice,
            library: library,
            fragmentFunctionName: "videoFragmentDither"
        )
        pipelineStateNoDither = try Self.createPipeline(
            device: mtlDevice,
            library: library,
            fragmentFunctionName: "videoFragmentPlain"
        )
    }

    private static func makeLibrary(device: MTLDevice) throws -> MTLLibrary {
        // Shader source with optional temporal dithering and contentRect support.
        let shaderSource = """
        #include <metal_stdlib>
        using namespace metal;

        struct VertexOut {
            float4 position [[position]];
            float2 texCoord;
        };

        struct Uniforms {
            uint frameCount;
            uint padding;
            uint padding2;
            uint padding3;
            float4 contentRect;  // x, y, width, height (normalized 0-1)
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

        // Interleaved gradient noise - high-quality per-pixel noise
        float interleavedGradientNoise(float2 screenPos) {
            float3 magic = float3(0.06711056, 0.00583715, 52.9829189);
            return fract(magic.z * fract(dot(screenPos, magic.xy)));
        }

        // Temporal variation using R2 sequence to prevent static noise patterns
        float temporalDither(float2 screenPos, uint frame) {
            float2 offset = float2(
                fract(float(frame) * 0.7548776662466927),
                fract(float(frame) * 0.5698402909980532)
            );
            return interleavedGradientNoise(screenPos + offset * 1000.0);
        }

        fragment float4 videoFragmentDither(
            VertexOut in [[stage_in]],
            texture2d<float> colorTexture [[texture(0)]],
            constant Uniforms& uniforms [[buffer(0)]]
        ) {
            constexpr sampler textureSampler(mag_filter::linear, min_filter::linear);
            float4 color = colorTexture.sample(textureSampler, in.texCoord);

            // Apply temporal dithering to reduce color banding
            // Noise centered around zero, scaled to 1 bit of 10-bit color
            float noise = (temporalDither(in.position.xy, uniforms.frameCount) - 0.5) / 1023.0;
            color.rgb += noise;

            return color;
        }

        fragment float4 videoFragmentPlain(
            VertexOut in [[stage_in]],
            texture2d<float> colorTexture [[texture(0)]]
        ) {
            constexpr sampler textureSampler(mag_filter::linear, min_filter::linear);
            return colorTexture.sample(textureSampler, in.texCoord);
        }
        """

        return try device.makeLibrary(source: shaderSource, options: nil)
    }

    private static func createPipeline(
        device: MTLDevice,
        library: MTLLibrary,
        fragmentFunctionName: String
    ) throws -> MTLRenderPipelineState {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "videoVertex")
        descriptor.fragmentFunction = library.makeFunction(name: fragmentFunctionName)
        descriptor.colorAttachments[0].pixelFormat = .bgr10a2Unorm

        return try device.makeRenderPipelineState(descriptor: descriptor)
    }

    /// Create a Metal texture from a CVPixelBuffer (zero-copy via IOSurface)
    func createTexture(from pixelBuffer: CVPixelBuffer) -> MTLTexture? {
        guard let cache = textureCache else { return nil }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let pixelFormatType = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let metalPixelFormat: MTLPixelFormat
        switch pixelFormatType {
        case kCVPixelFormatType_32BGRA:
            metalPixelFormat = .bgra8Unorm
        case kCVPixelFormatType_ARGB2101010LEPacked:
            metalPixelFormat = .bgr10a2Unorm
        default:
            metalPixelFormat = .bgr10a2Unorm
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

        guard status == kCVReturnSuccess, let metalTexture else {
            return nil
        }

        return CVMetalTextureGetTexture(metalTexture)
    }

    /// Render a texture to a drawable with optional contentRect for cropping SCK black bars
    /// - Parameters:
    ///   - texture: The source texture to render
    ///   - drawable: The drawable to render to
    ///   - contentRect: The region containing actual content (in pixels). If nil or empty, uses full texture.
    func render(texture: MTLTexture, to drawable: CAMetalDrawable, contentRect: CGRect? = nil) {
        let signpostState = MirageSignpost.beginInterval("Render")
        defer { MirageSignpost.endInterval("Render", signpostState) }

        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = drawable.texture
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].storeAction = .store
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            return
        }

        let pipelineState = temporalDitheringEnabled ? pipelineStateDither : pipelineStateNoDither
        encoder.setRenderPipelineState(pipelineState)
        encoder.setFragmentTexture(texture, index: 0)

        // Calculate normalized contentRect (0-1 range)
        let textureWidth = Float(texture.width)
        let textureHeight = Float(texture.height)

        let normalizedRect: SIMD4<Float>
        if let rect = contentRect, !rect.isEmpty {
            // Normalize contentRect to 0-1 UV space
            normalizedRect = SIMD4<Float>(
                Float(rect.origin.x) / textureWidth,
                Float(rect.origin.y) / textureHeight,
                Float(rect.width) / textureWidth,
                Float(rect.height) / textureHeight
            )

            // Log contentRect usage every ~2 seconds
            if frameCount % 120 == 1 {
                MirageLogger.renderer("contentRect: \(rect) -> normalized: (\(normalizedRect.x), \(normalizedRect.y), \(normalizedRect.z), \(normalizedRect.w)) texture: \(Int(textureWidth))x\(Int(textureHeight))")
            }
        } else {
            // No contentRect or empty - use full texture
            normalizedRect = SIMD4<Float>(0, 0, 1, 1)
        }

        // Update uniforms
        frameCount = frameCount &+ 1
        var uniforms = RenderUniforms(
            frameCount: frameCount,
            contentRect: normalizedRect
        )
        uniformsBuffer?.contents().copyMemory(from: &uniforms, byteCount: MemoryLayout<RenderUniforms>.size)

        // Bind uniforms to both vertex and fragment shaders
        encoder.setVertexBuffer(uniformsBuffer, offset: 0, index: 0)
        encoder.setFragmentBuffer(uniformsBuffer, offset: 0, index: 0)

        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    /// Render a pixel buffer directly to a drawable
    func render(pixelBuffer: CVPixelBuffer, to drawable: CAMetalDrawable, contentRect: CGRect? = nil) {
        guard let texture = createTexture(from: pixelBuffer) else { return }

        // Log dimension mismatch every 120 frames (~2 seconds at 60fps)
        if frameCount % 120 == 0 {
            let drawableW = drawable.texture.width
            let drawableH = drawable.texture.height
            let textureW = texture.width
            let textureH = texture.height
            if drawableW != textureW || drawableH != textureH {
                MirageLogger.renderer("Dimension mismatch - Drawable: \(drawableW)x\(drawableH), Texture: \(textureW)x\(textureH)")
            }
            if let rect = contentRect, !rect.isEmpty {
                MirageLogger.renderer("contentRect: \(rect) (texture: \(textureW)x\(textureH))")
            }
        }

        render(texture: texture, to: drawable, contentRect: contentRect)
    }

    /// Flush the texture cache
    func flushCache() {
        if let cache = textureCache {
            CVMetalTextureCacheFlush(cache, 0)
        }
    }

    func setTemporalDitheringEnabled(_ enabled: Bool) {
        temporalDitheringEnabled = enabled
    }
}
