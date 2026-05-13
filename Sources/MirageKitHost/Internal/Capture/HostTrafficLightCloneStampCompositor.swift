//
//  HostTrafficLightCloneStampCompositor.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/1/26.
//

import CoreVideo
import Foundation
import Metal
import MirageKit

#if os(macOS)
final class HostTrafficLightCloneStampCompositor: @unchecked Sendable {
    enum SkipReason: String, Sendable {
        case unsupportedPixelFormat
        case invalidContentRect
        case invalidWindowFrame
        case emptyDestination
        case emptySource
        case metalUnavailable
        case pipelineCreationFailed
        case textureCacheUnavailable
        case textureCreationFailed
        case commandBufferUnavailable
        case encoderUnavailable
        case uniformBufferUnavailable
        case commandBufferFailed
    }

    enum ApplyResult: Sendable {
        case applied
        case skipped(SkipReason)
    }

    private struct PlaneTextures {
        let textures: [MTLTexture]
        let fullWidth: Int
        let fullHeight: Int
    }

    private struct CloneStampUniforms {
        var destinationOrigin: SIMD2<UInt32>
        var destinationSize: SIMD2<UInt32>
        var sourceOrigin: SIMD2<UInt32>
        var sourceSize: SIMD2<UInt32>
        var maskOrigin: SIMD2<UInt32>
        var maskSize: SIMD2<UInt32>
        var featherPixels: Float
        var blurRadiusPixels: Float
        var blendStrength: Float
    }

    private struct PixelRect {
        let originX: Int
        let originY: Int
        let width: Int
        let height: Int

        var isEmpty: Bool {
            width <= 0 || height <= 0
        }
    }

    private let device: MTLDevice?
    private let commandQueue: MTLCommandQueue?
    private let pipelineState: MTLComputePipelineState?
    private var textureCache: CVMetalTextureCache?

    init(device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        self.device = device

        guard let device else {
            commandQueue = nil
            pipelineState = nil
            textureCache = nil
            return
        }

        commandQueue = device.makeCommandQueue()

        do {
            let library = try Self.makeLibrary(device: device)
            guard let kernel = library.makeFunction(name: "cloneStampPlane") else {
                pipelineState = nil
                textureCache = nil
                return
            }
            pipelineState = try device.makeComputePipelineState(function: kernel)
        } catch {
            pipelineState = nil
        }

        var cache: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        if status == kCVReturnSuccess {
            textureCache = cache
        } else {
            textureCache = nil
        }
    }

    func apply(
        to pixelBuffer: CVPixelBuffer,
        contentRect: CGRect,
        geometry: HostTrafficLightMaskGeometryResolver.ResolvedGeometry
    ) -> ApplyResult {
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let decision = HostTrafficLightCloneStampPlanner.makeDecision(
            pixelFormat: pixelFormat,
            contentRect: contentRect,
            geometry: geometry
        )

        let plan: HostTrafficLightCloneStampPlan
        switch decision {
        case let .apply(resolvedPlan):
            plan = resolvedPlan
        case let .skip(reason):
            return .skipped(Self.mapPlannerSkipReason(reason))
        }

        guard let commandQueue else {
            return .skipped(.metalUnavailable)
        }
        guard let pipelineState else {
            return .skipped(.pipelineCreationFailed)
        }
        guard textureCache != nil else {
            return .skipped(.textureCacheUnavailable)
        }

        guard let planeTextures = makePlaneTextures(pixelBuffer: pixelBuffer, pixelFormat: pixelFormat) else {
            return .skipped(.textureCreationFailed)
        }

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            return .skipped(.commandBufferUnavailable)
        }
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return .skipped(.encoderUnavailable)
        }

        encoder.setComputePipelineState(pipelineState)
        var didDispatch = false

        for texture in planeTextures.textures {
            let planeScaleX = CGFloat(texture.width) / CGFloat(planeTextures.fullWidth)
            let planeScaleY = CGFloat(texture.height) / CGFloat(planeTextures.fullHeight)
            let scaledPlan = plan.scaled(x: planeScaleX, y: planeScaleY)

            let destination = pixelRect(from: scaledPlan.destinationRect, limitWidth: texture.width, limitHeight: texture.height)
            let source = pixelRect(from: scaledPlan.sourceRect, limitWidth: texture.width, limitHeight: texture.height)
            let mask = pixelRect(from: scaledPlan.maskRect, limitWidth: texture.width, limitHeight: texture.height)

            guard !destination.isEmpty, !source.isEmpty, !mask.isEmpty else { continue }
            didDispatch = true

            var uniforms = CloneStampUniforms(
                destinationOrigin: SIMD2(UInt32(destination.originX), UInt32(destination.originY)),
                destinationSize: SIMD2(UInt32(destination.width), UInt32(destination.height)),
                sourceOrigin: SIMD2(UInt32(source.originX), UInt32(source.originY)),
                sourceSize: SIMD2(UInt32(source.width), UInt32(source.height)),
                maskOrigin: SIMD2(UInt32(mask.originX), UInt32(mask.originY)),
                maskSize: SIMD2(UInt32(mask.width), UInt32(mask.height)),
                featherPixels: scaledPlan.featherPixels,
                blurRadiusPixels: scaledPlan.blurRadiusPixels,
                blendStrength: scaledPlan.blendStrength
            )

            guard let uniformsBuffer = device?.makeBuffer(
                bytes: &uniforms,
                length: MemoryLayout<CloneStampUniforms>.stride,
                options: .storageModeShared
            ) else {
                encoder.endEncoding()
                return .skipped(.uniformBufferUnavailable)
            }

            encoder.setTexture(texture, index: 0)
            encoder.setBuffer(uniformsBuffer, offset: 0, index: 0)

            let width = destination.width
            let height = destination.height
            let threadWidth = max(1, pipelineState.threadExecutionWidth)
            let threadHeight = max(1, pipelineState.maxTotalThreadsPerThreadgroup / threadWidth)
            let threadsPerGroup = MTLSize(width: threadWidth, height: threadHeight, depth: 1)
            let threadgroups = MTLSize(
                width: (width + threadWidth - 1) / threadWidth,
                height: (height + threadHeight - 1) / threadHeight,
                depth: 1
            )

            encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadsPerGroup)
        }

        guard didDispatch else {
            encoder.endEncoding()
            return .skipped(.emptyDestination)
        }

        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        if commandBuffer.status == .error {
            return .skipped(.commandBufferFailed)
        }

        return .applied
    }

    private static func mapPlannerSkipReason(_ reason: HostTrafficLightCloneStampPlanner.SkipReason) -> SkipReason {
        switch reason {
        case .unsupportedPixelFormat:
            return .unsupportedPixelFormat
        case .invalidContentRect:
            return .invalidContentRect
        case .invalidWindowFrame:
            return .invalidWindowFrame
        case .emptyDestination:
            return .emptyDestination
        case .emptySource:
            return .emptySource
        }
    }

    private func makePlaneTextures(pixelBuffer: CVPixelBuffer, pixelFormat: OSType) -> PlaneTextures? {
        guard let textureCache else { return nil }

        let fullWidth = CVPixelBufferGetWidth(pixelBuffer)
        let fullHeight = CVPixelBufferGetHeight(pixelBuffer)

        let textureAttributes: [CFString: Any] = [
            kCVMetalTextureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue | MTLTextureUsage.shaderWrite.rawValue),
        ]

        switch pixelFormat {
        case kCVPixelFormatType_32BGRA:
            guard let texture = makeTexture(
                pixelBuffer: pixelBuffer,
                planeIndex: 0,
                width: fullWidth,
                height: fullHeight,
                pixelFormat: .bgra8Unorm,
                attributes: textureAttributes,
                textureCache: textureCache
            ) else {
                return nil
            }
            return PlaneTextures(textures: [texture], fullWidth: fullWidth, fullHeight: fullHeight)

        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
             kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            guard let yTexture = makeTexture(
                pixelBuffer: pixelBuffer,
                planeIndex: 0,
                width: CVPixelBufferGetWidthOfPlane(pixelBuffer, 0),
                height: CVPixelBufferGetHeightOfPlane(pixelBuffer, 0),
                pixelFormat: .r8Unorm,
                attributes: textureAttributes,
                textureCache: textureCache
            ),
            let uvTexture = makeTexture(
                pixelBuffer: pixelBuffer,
                planeIndex: 1,
                width: CVPixelBufferGetWidthOfPlane(pixelBuffer, 1),
                height: CVPixelBufferGetHeightOfPlane(pixelBuffer, 1),
                pixelFormat: .rg8Unorm,
                attributes: textureAttributes,
                textureCache: textureCache
            ) else {
                return nil
            }
            return PlaneTextures(textures: [yTexture, uvTexture], fullWidth: fullWidth, fullHeight: fullHeight)

        case kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
             kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange:
            guard let yTexture = makeTexture(
                pixelBuffer: pixelBuffer,
                planeIndex: 0,
                width: CVPixelBufferGetWidthOfPlane(pixelBuffer, 0),
                height: CVPixelBufferGetHeightOfPlane(pixelBuffer, 0),
                pixelFormat: .r16Unorm,
                attributes: textureAttributes,
                textureCache: textureCache
            ),
            let uvTexture = makeTexture(
                pixelBuffer: pixelBuffer,
                planeIndex: 1,
                width: CVPixelBufferGetWidthOfPlane(pixelBuffer, 1),
                height: CVPixelBufferGetHeightOfPlane(pixelBuffer, 1),
                pixelFormat: .rg16Unorm,
                attributes: textureAttributes,
                textureCache: textureCache
            ) else {
                return nil
            }
            return PlaneTextures(textures: [yTexture, uvTexture], fullWidth: fullWidth, fullHeight: fullHeight)

        case kCVPixelFormatType_444YpCbCr10BiPlanarFullRange:
            guard let yTexture = makeTexture(
                pixelBuffer: pixelBuffer,
                planeIndex: 0,
                width: CVPixelBufferGetWidthOfPlane(pixelBuffer, 0),
                height: CVPixelBufferGetHeightOfPlane(pixelBuffer, 0),
                pixelFormat: .r16Unorm,
                attributes: textureAttributes,
                textureCache: textureCache
            ),
            let uvTexture = makeTexture(
                pixelBuffer: pixelBuffer,
                planeIndex: 1,
                width: CVPixelBufferGetWidthOfPlane(pixelBuffer, 1),
                height: CVPixelBufferGetHeightOfPlane(pixelBuffer, 1),
                pixelFormat: .rg16Unorm,
                attributes: textureAttributes,
                textureCache: textureCache
            ) else {
                return nil
            }
            return PlaneTextures(textures: [yTexture, uvTexture], fullWidth: fullWidth, fullHeight: fullHeight)

        default:
            return nil
        }
    }

    private func makeTexture(
        pixelBuffer: CVPixelBuffer,
        planeIndex: Int,
        width: Int,
        height: Int,
        pixelFormat: MTLPixelFormat,
        attributes: [CFString: Any],
        textureCache: CVMetalTextureCache
    ) -> MTLTexture? {
        var textureRef: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            attributes as CFDictionary,
            pixelFormat,
            width,
            height,
            planeIndex,
            &textureRef
        )

        guard status == kCVReturnSuccess,
              let textureRef else {
            return nil
        }
        return CVMetalTextureGetTexture(textureRef)
    }

    private func pixelRect(from rect: CGRect, limitWidth: Int, limitHeight: Int) -> PixelRect {
        if rect.width <= 0 || rect.height <= 0 {
            return PixelRect(originX: 0, originY: 0, width: 0, height: 0)
        }

        let minX = max(0, min(Int(floor(rect.minX)), limitWidth))
        let minY = max(0, min(Int(floor(rect.minY)), limitHeight))
        let maxX = max(minX, min(Int(ceil(rect.maxX)), limitWidth))
        let maxY = max(minY, min(Int(ceil(rect.maxY)), limitHeight))

        return PixelRect(
            originX: minX,
            originY: minY,
            width: maxX - minX,
            height: maxY - minY
        )
    }

}
#endif
