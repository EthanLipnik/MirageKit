//
//  MirageMetalRenderState.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/23/26.
//

import CoreGraphics
import CoreVideo
import Foundation
import MirageKit

final class MirageMetalRenderState {
    private var needsRedraw = true

    private(set) var currentPixelBuffer: CVPixelBuffer?
    private(set) var currentContentRect: CGRect = .zero
    private(set) var currentPixelFormatType: OSType?
    private(set) var currentSequence: UInt64 = 0
    private(set) var currentDecodeTime: CFAbsoluteTime = 0

    func reset() {
        needsRedraw = true
        currentPixelBuffer = nil
        currentContentRect = .zero
        currentPixelFormatType = nil
        currentSequence = 0
        currentDecodeTime = 0
    }

    func markNeedsRedraw() {
        needsRedraw = true
    }

    @discardableResult
    func updateFrameIfNeeded(
        streamID: StreamID?,
        catchUpDepth: Int = 2,
        preferLatest: Bool = false
    ) -> Bool {
        if let id = streamID,
           let entry = MirageFrameCache.shared.dequeueForPresentation(
               for: id,
               catchUpDepth: catchUpDepth,
               preferLatest: preferLatest
           ) {
            currentPixelBuffer = entry.pixelBuffer
            currentPixelFormatType = CVPixelBufferGetPixelFormatType(entry.pixelBuffer)
            currentContentRect = entry.contentRect
            currentSequence = entry.sequence
            currentDecodeTime = entry.decodeTime
            needsRedraw = false
            return true
        }

        guard needsRedraw else { return false }
        needsRedraw = false
        return currentPixelBuffer != nil
    }
}
