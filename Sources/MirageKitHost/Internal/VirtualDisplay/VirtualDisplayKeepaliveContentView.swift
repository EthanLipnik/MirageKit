//
//  VirtualDisplayKeepaliveContentView.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/21/26.
//

#if os(macOS)
import AppKit
import Metal
import QuartzCore

@MainActor
final class VirtualDisplayKeepaliveContentView: NSView {
    private let metalDevice: MTLDevice?
    private let commandQueue: MTLCommandQueue?

    init(frame: CGRect, alpha: CGFloat) {
        metalDevice = MTLCreateSystemDefaultDevice()
        commandQueue = metalDevice?.makeCommandQueue()
        super.init(frame: frame)
        wantsLayer = true
        if let metalDevice {
            let metalLayer = CAMetalLayer()
            metalLayer.device = metalDevice
            metalLayer.pixelFormat = .bgra8Unorm
            metalLayer.framebufferOnly = true
            metalLayer.isOpaque = false
            metalLayer.backgroundColor = NSColor.black.withAlphaComponent(alpha).cgColor
            metalLayer.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
            metalLayer.drawableSize = backingDrawableSize
            metalLayer.allowsNextDrawableTimeout = false
            layer = metalLayer
        } else {
            layer = CALayer()
            layer?.backgroundColor = NSColor.black.withAlphaComponent(alpha).cgColor
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        guard let metalLayer = layer as? CAMetalLayer else { return }
        metalLayer.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        metalLayer.drawableSize = backingDrawableSize
    }

    func drawDirtyFrame(tick: UInt64, alphaLow: CGFloat, alphaHigh: CGFloat) -> Bool {
        let alpha = tick.isMultiple(of: 2) ? alphaLow : alphaHigh
        guard drawMetalFrame(tick: tick, alpha: alpha) else {
            drawLayerFrame(alpha: alpha)
            return false
        }
        return true
    }

    private var backingDrawableSize: CGSize {
        let backingBounds = convertToBacking(bounds)
        return CGSize(
            width: max(1, backingBounds.width),
            height: max(1, backingBounds.height)
        )
    }

    private func drawMetalFrame(tick: UInt64, alpha: CGFloat) -> Bool {
        guard let metalLayer = layer as? CAMetalLayer,
              let commandQueue,
              let drawable = metalLayer.nextDrawable(),
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            return false
        }
        let descriptor = MTLRenderPassDescriptor()
        let color = tick.isMultiple(of: 2) ? 0.0 : 0.18
        descriptor.colorAttachments[0].texture = drawable.texture
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = MTLClearColor(
            red: color,
            green: color,
            blue: color,
            alpha: Double(alpha)
        )
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            return false
        }
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
        return true
    }

    private func drawLayerFrame(alpha: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.backgroundColor = NSColor.black.withAlphaComponent(alpha).cgColor
        layer?.setNeedsDisplay()
        CATransaction.commit()
    }
}
#endif
