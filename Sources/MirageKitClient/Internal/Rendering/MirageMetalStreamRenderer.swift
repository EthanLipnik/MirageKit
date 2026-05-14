//
//  MirageMetalStreamRenderer.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/14/26.
//

#if canImport(CoreImage) && canImport(Metal) && canImport(QuartzCore)
import CoreGraphics
import CoreImage
import CoreVideo
import Metal
import QuartzCore

/// Metal-backed pixel-buffer renderer used by the client-owned presentation path.
///
/// The renderer is intentionally independent of UIKit/AppKit view ownership so
/// the platform views can cut over from AVSampleBufferDisplayLayer to CAMetalLayer
/// without changing decode or playout policy.
final class MirageMetalStreamRenderer: @unchecked Sendable {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let ciContext: CIContext

    init?(device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        guard let device,
              let commandQueue = device.makeCommandQueue() else {
            return nil
        }
        self.device = device
        self.commandQueue = commandQueue
        self.ciContext = CIContext(
            mtlDevice: device,
            options: [
                .cacheIntermediates: false,
                .name: "MirageMetalStreamRenderer",
            ]
        )
    }

    func configure(layer: CAMetalLayer, scale: CGFloat) {
        layer.device = device
        layer.framebufferOnly = false
        layer.contentsScale = scale
        layer.pixelFormat = .bgra8Unorm
    }

    @discardableResult
    func render(
        pixelBuffer: CVPixelBuffer,
        contentRect: CGRect,
        into layer: CAMetalLayer
    ) -> Bool {
        guard let drawable = layer.nextDrawable(),
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            return false
        }

        var image = CIImage(cvPixelBuffer: pixelBuffer)
        let cropRect = resolvedCropRect(
            contentRect: contentRect,
            pixelBuffer: pixelBuffer
        )
        if cropRect != image.extent {
            image = image.cropped(to: cropRect)
        }

        let targetBounds = CGRect(
            origin: .zero,
            size: CGSize(width: drawable.texture.width, height: drawable.texture.height)
        )
        let scaled = image.transformed(
            by: transform(from: image.extent, to: targetBounds)
        )

        ciContext.render(
            scaled,
            to: drawable.texture,
            commandBuffer: commandBuffer,
            bounds: targetBounds,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        commandBuffer.present(drawable)
        commandBuffer.commit()
        return true
    }

    private func resolvedCropRect(
        contentRect: CGRect,
        pixelBuffer: CVPixelBuffer
    ) -> CGRect {
        let width = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let height = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        let fullRect = CGRect(x: 0, y: 0, width: width, height: height)
        guard contentRect.width > 0,
              contentRect.height > 0 else {
            return fullRect
        }
        return contentRect.intersection(fullRect)
    }

    private func transform(from source: CGRect, to target: CGRect) -> CGAffineTransform {
        guard source.width > 0,
              source.height > 0,
              target.width > 0,
              target.height > 0 else {
            return .identity
        }
        let scaleX = target.width / source.width
        let scaleY = target.height / source.height
        return CGAffineTransform(translationX: -source.origin.x, y: -source.origin.y)
            .scaledBy(x: scaleX, y: scaleY)
    }
}
#endif
