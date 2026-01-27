//
//  MirageMetalRenderState.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/23/26.
//

import CoreGraphics
import CoreVideo

final class MirageMetalRenderState {
    private var lastRenderedSequence: UInt64 = 0
    private var needsRedraw = true

    private(set) var currentPixelBuffer: CVPixelBuffer?
    private(set) var currentContentRect: CGRect = .zero
    private(set) var currentPixelFormatType: OSType?

    func reset() {
        lastRenderedSequence = 0
        needsRedraw = true
        currentPixelBuffer = nil
        currentContentRect = .zero
        currentPixelFormatType = nil
    }

    func markNeedsRedraw() {
        needsRedraw = true
    }

    @discardableResult
    func updateFrameIfNeeded(streamID: StreamID?) -> Bool {
        guard let id = streamID, let entry = MirageFrameCache.shared.getEntry(for: id) else { return false }
        let hasNewFrame = entry.sequence != lastRenderedSequence
        guard hasNewFrame || needsRedraw else { return false }

        if hasNewFrame {
            currentPixelBuffer = entry.pixelBuffer
            currentPixelFormatType = CVPixelBufferGetPixelFormatType(entry.pixelBuffer)
            currentContentRect = entry.contentRect
            lastRenderedSequence = entry.sequence
        }

        needsRedraw = false
        return currentPixelBuffer != nil
    }
}
