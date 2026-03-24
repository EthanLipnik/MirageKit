//
//  HostTrafficLightCloneStampCompositor.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/1/26.
//

import CoreGraphics
import CoreVideo
import Foundation
import Metal
import MirageKit

#if os(macOS)
struct HostTrafficLightCloneStampPlan: Sendable {
    let destinationRect: CGRect
    let sourceRect: CGRect
    let maskRect: CGRect
    let featherPixels: Float
    let blurRadiusPixels: Float
    let blendStrength: Float

    func scaled(x scaleX: CGFloat, y scaleY: CGFloat) -> HostTrafficLightCloneStampPlan {
        HostTrafficLightCloneStampPlan(
            destinationRect: CGRect(
                x: destinationRect.origin.x * scaleX,
                y: destinationRect.origin.y * scaleY,
                width: destinationRect.width * scaleX,
                height: destinationRect.height * scaleY
            ),
            sourceRect: CGRect(
                x: sourceRect.origin.x * scaleX,
                y: sourceRect.origin.y * scaleY,
                width: sourceRect.width * scaleX,
                height: sourceRect.height * scaleY
            ),
            maskRect: CGRect(
                x: maskRect.origin.x * scaleX,
                y: maskRect.origin.y * scaleY,
                width: maskRect.width * scaleX,
                height: maskRect.height * scaleY
            ),
            featherPixels: featherPixels,
            blurRadiusPixels: blurRadiusPixels,
            blendStrength: blendStrength
        )
    }
}

enum HostTrafficLightCloneStampPlanner {
    enum SkipReason: String, Sendable {
        case unsupportedPixelFormat
        case invalidContentRect
        case invalidWindowFrame
        case emptyDestination
        case emptySource
    }

    enum Decision: Sendable {
        case apply(HostTrafficLightCloneStampPlan)
        case skip(SkipReason)
    }

    private static let minimumDestinationSize: CGFloat = 4
    private static let minimumMaskSize: CGFloat = 4
    private static let minimumSourceThickness: CGFloat = 1
    private static let maximumSourceThickness: CGFloat = 4
    private static let sourceGap: CGFloat = 1

    static func makeDecision(
        pixelFormat: OSType,
        contentRect: CGRect,
        geometry: HostTrafficLightMaskGeometryResolver.ResolvedGeometry
    ) -> Decision {
        guard isSupportedPixelFormat(pixelFormat) else {
            return .skip(.unsupportedPixelFormat)
        }
        guard contentRect.width > 0, contentRect.height > 0 else {
            return .skip(.invalidContentRect)
        }
        guard geometry.windowFramePoints.width > 0, geometry.windowFramePoints.height > 0 else {
            return .skip(.invalidWindowFrame)
        }
        let scaleX = contentRect.width / geometry.windowFramePoints.width
        let scaleY = contentRect.height / geometry.windowFramePoints.height

        var destinationRect = CGRect(
            x: contentRect.minX + geometry.clusterRectPoints.minX * scaleX,
            y: contentRect.minY + geometry.clusterRectPoints.minY * scaleY,
            width: geometry.clusterRectPoints.width * scaleX,
            height: geometry.clusterRectPoints.height * scaleY
        )
        destinationRect = destinationRect.intersection(contentRect)

        guard destinationRect.width >= minimumDestinationSize,
              destinationRect.height >= minimumDestinationSize else {
            return .skip(.emptyDestination)
        }

        let sourceThickness = max(
            minimumSourceThickness,
            min(maximumSourceThickness, floor(destinationRect.height * 0.06))
        )

        let rightCandidate = CGRect(
            x: destinationRect.maxX + sourceGap,
            y: destinationRect.minY,
            width: sourceThickness,
            height: destinationRect.height
        )
        let belowCandidate = CGRect(
            x: destinationRect.minX,
            y: destinationRect.maxY + sourceGap,
            width: destinationRect.width,
            height: sourceThickness
        )

        let sourceRect: CGRect
        if contains(rightCandidate, in: contentRect) {
            sourceRect = rightCandidate
        } else if contains(belowCandidate, in: contentRect) {
            sourceRect = belowCandidate
        } else {
            let clampedRight = clampedRect(rightCandidate, in: contentRect)
            let clampedBelow = clampedRect(belowCandidate, in: contentRect)
            if clampedRight.width * clampedRight.height >= clampedBelow.width * clampedBelow.height {
                sourceRect = clampedRight
            } else {
                sourceRect = clampedBelow
            }
        }

        guard sourceRect.width >= minimumSourceThickness,
              sourceRect.height >= minimumSourceThickness,
              max(sourceRect.width, sourceRect.height) >= minimumDestinationSize else {
            return .skip(.emptySource)
        }

        let maskRect = resolvedMaskRect(destinationRect: destinationRect, geometry: geometry)
        guard maskRect.width >= minimumMaskSize, maskRect.height >= minimumMaskSize else {
            return .skip(.emptyDestination)
        }

        let featherPixels = Float(max(1.25, min(3.4, maskRect.height * 0.18)))
        let blurRadiusPixels = Float(max(0.45, min(1.1, maskRect.height * 0.06)))

        return .apply(
            HostTrafficLightCloneStampPlan(
                destinationRect: destinationRect,
                sourceRect: sourceRect,
                maskRect: maskRect,
                featherPixels: featherPixels,
                blurRadiusPixels: blurRadiusPixels,
                blendStrength: 1.0
            )
        )
    }

    static func isSupportedPixelFormat(_ pixelFormat: OSType) -> Bool {
        switch pixelFormat {
        case kCVPixelFormatType_32BGRA,
             kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
             kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
             kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
             kCVPixelFormatType_444YpCbCr10BiPlanarFullRange:
            return true
        default:
            return false
        }
    }

    private static func contains(_ candidate: CGRect, in rect: CGRect) -> Bool {
        candidate.minX >= rect.minX &&
            candidate.minY >= rect.minY &&
            candidate.maxX <= rect.maxX &&
            candidate.maxY <= rect.maxY
    }

    private static func clampedRect(_ rect: CGRect, in bounds: CGRect) -> CGRect {
        guard bounds.width > 0, bounds.height > 0 else { return .zero }

        let width = min(rect.width, bounds.width)
        let height = min(rect.height, bounds.height)
        let x = min(max(rect.minX, bounds.minX), bounds.maxX - width)
        let y = min(max(rect.minY, bounds.minY), bounds.maxY - height)

        return CGRect(x: x, y: y, width: width, height: height)
    }

    private static func resolvedMaskRect(
        destinationRect: CGRect,
        geometry: HostTrafficLightMaskGeometryResolver.ResolvedGeometry
    ) -> CGRect {
        if let buttonUnionRectInCluster = geometry.buttonUnionRectInClusterPoints,
           geometry.clusterRectPoints.width > 0,
           geometry.clusterRectPoints.height > 0 {
            let scaleX = destinationRect.width / geometry.clusterRectPoints.width
            let scaleY = destinationRect.height / geometry.clusterRectPoints.height
            let axMaskRect = CGRect(
                x: destinationRect.minX + buttonUnionRectInCluster.minX * scaleX,
                y: destinationRect.minY + buttonUnionRectInCluster.minY * scaleY,
                width: buttonUnionRectInCluster.width * scaleX,
                height: buttonUnionRectInCluster.height * scaleY
            ).intersection(destinationRect)
            let paddedAXMaskRect = axMaskRect
                .insetBy(dx: -1.5, dy: -1.5)
                .intersection(destinationRect)
            if paddedAXMaskRect.width >= minimumMaskSize, paddedAXMaskRect.height >= minimumMaskSize {
                return paddedAXMaskRect
            }
            if axMaskRect.width >= minimumMaskSize, axMaskRect.height >= minimumMaskSize {
                return axMaskRect
            }
        }

        let fallbackInsetX = max(2, destinationRect.height * 0.14)
        let fallbackInsetY = max(2, destinationRect.height * 0.14)
        let fallbackHeight = max(minimumMaskSize, min(destinationRect.height * 0.52, destinationRect.height - fallbackInsetY))
        let fallbackWidth = max(
            minimumMaskSize,
            min(destinationRect.width - fallbackInsetX, fallbackHeight * 3.8)
        )

        return CGRect(
            x: destinationRect.minX + fallbackInsetX,
            y: destinationRect.minY + fallbackInsetY,
            width: fallbackWidth,
            height: fallbackHeight
        ).intersection(destinationRect)
    }
}

final class HostTrafficLightCloneStampCompositor {
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

    private static func makeLibrary(device: MTLDevice) throws -> MTLLibrary {
        let shaderSource = """
        #include <metal_stdlib>
        using namespace metal;

        struct CloneStampUniforms {
            uint2 destinationOrigin;
            uint2 destinationSize;
            uint2 sourceOrigin;
            uint2 sourceSize;
            uint2 maskOrigin;
            uint2 maskSize;
            float featherPixels;
            float blurRadiusPixels;
            float blendStrength;
        };

        kernel void cloneStampPlane(
            texture2d<float, access::read_write> plane [[texture(0)]],
            constant CloneStampUniforms& uniforms [[buffer(0)]],
            uint2 gid [[thread_position_in_grid]]
        ) {
            if (gid.x >= uniforms.destinationSize.x || gid.y >= uniforms.destinationSize.y) {
                return;
            }

            uint2 destination = gid + uniforms.destinationOrigin;
            float2 local = (float2(gid) + 0.5) / float2(max(uniforms.destinationSize, uint2(1, 1)));
            float2 sourceCenter = float2(uniforms.sourceOrigin) + local * float2(uniforms.sourceSize);

            float2 sampleOffsets[9] = {
                float2(-1, -1),
                float2(0, -1),
                float2(1, -1),
                float2(-1, 0),
                float2(0, 0),
                float2(1, 0),
                float2(-1, 1),
                float2(0, 1),
                float2(1, 1)
            };

            float sampleWeights[9] = {
                0.0625,
                0.125,
                0.0625,
                0.125,
                0.25,
                0.125,
                0.0625,
                0.125,
                0.0625
            };

            int2 maxCoord = int2(int(plane.get_width()) - 1, int(plane.get_height()) - 1);
            float4 cloned = float4(0.0);

            for (uint index = 0; index < 9; ++index) {
                float2 offset = sampleOffsets[index] * uniforms.blurRadiusPixels;
                int2 sampleCoord = int2(round(sourceCenter + offset));
                sampleCoord = clamp(sampleCoord, int2(0, 0), maxCoord);
                cloned += plane.read(uint2(sampleCoord)) * sampleWeights[index];
            }

            float2 destinationPoint = float2(destination) + 0.5;
            float2 maskOrigin = float2(uniforms.maskOrigin);
            float2 maskSize = float2(max(uniforms.maskSize, uint2(1, 1)));
            float feather = max(uniforms.featherPixels, 1.0);

            // Capsule SDF covering the sharing indicator pill shape.
            float capsuleRadius = max(2.0, maskSize.y * 0.6);
            float centerY = maskOrigin.y + maskSize.y * 0.5;
            float2 capA = float2(maskOrigin.x + capsuleRadius, centerY);
            float2 capB = float2(maskOrigin.x + maskSize.x - capsuleRadius, centerY);
            float2 pa = destinationPoint - capA;
            float2 ba = capB - capA;
            float segLen = max(dot(ba, ba), 0.0001);
            float h = clamp(dot(pa, ba) / segLen, 0.0, 1.0);
            float d = length(pa - ba * h) - capsuleRadius;
            float alpha = 1.0 - smoothstep(-feather * 0.5, feather, d);

            // Keep blending tightly confined to the mask bounding region.
            float rectLeft = destinationPoint.x - maskOrigin.x;
            float rectRight = (maskOrigin.x + maskSize.x) - destinationPoint.x;
            float rectTop = destinationPoint.y - maskOrigin.y;
            float rectBottom = (maskOrigin.y + maskSize.y) - destinationPoint.y;
            float rectDistance = min(min(rectLeft, rectRight), min(rectTop, rectBottom));
            float rectGateFeather = max(1.0, feather * 0.45);
            float rectGate = smoothstep(-rectGateFeather, rectGateFeather, rectDistance);
            alpha *= rectGate;
            alpha = clamp(alpha, 0.0, 1.0);
            alpha = pow(alpha, 0.72);

            float4 original = plane.read(destination);
            float blend = uniforms.blendStrength * alpha;
            float4 outputValue = mix(original, cloned, blend);
            plane.write(outputValue, destination);
        }
        """

        return try device.makeLibrary(source: shaderSource, options: nil)
    }
}
#endif
