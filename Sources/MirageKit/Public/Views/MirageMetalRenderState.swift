//
//  MirageMetalRenderState.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/23/26.
//

import CoreGraphics
import CoreVideo
import Metal

final class MirageMetalRenderState {
    private weak var lastPixelBuffer: CVPixelBuffer?
    private var lastRenderedSequence: UInt64 = 0
    private var needsRedraw = true

    private(set) var currentTexture: MTLTexture?
    private(set) var currentContentRect: CGRect = .zero

    func reset() {
        lastRenderedSequence = 0
        needsRedraw = true
        lastPixelBuffer = nil
    }

    func markNeedsRedraw() {
        needsRedraw = true
    }

    func updateFrameIfNeeded(streamID: StreamID?, renderer: MetalRenderer?) {
        guard let id = streamID, let entry = MirageFrameCache.shared.getEntry(for: id) else { return }
        if entry.sequence == lastRenderedSequence && !needsRedraw {
            return
        }

        let pixelBuffer = entry.pixelBuffer
        if pixelBuffer !== lastPixelBuffer {
            currentTexture = renderer?.createTexture(from: pixelBuffer)
            lastPixelBuffer = pixelBuffer
        }

        currentContentRect = entry.contentRect
        lastRenderedSequence = entry.sequence
        needsRedraw = false
    }
}
