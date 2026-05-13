//
//  HostTrafficLightCloneStampCompositor+Shader.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/12/26.
//

import Foundation
import Metal

#if os(macOS)
extension HostTrafficLightCloneStampCompositor {
    /// Builds the Metal library that clone-stamps the host sharing indicator out of captured planes.
    static func makeLibrary(device: MTLDevice) throws -> MTLLibrary {
        try device.makeLibrary(source: cloneStampShaderSource, options: nil)
    }

    /// Metal source for cloning nearby frame content over the host sharing indicator region.
    static let cloneStampShaderSource = """
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
}
#endif
