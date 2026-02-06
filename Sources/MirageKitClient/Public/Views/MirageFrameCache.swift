//
//  MirageFrameCache.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/23/26.
//

import CoreVideo
import Foundation
import Metal
import MirageKit

// MARK: - Global Frame Cache (iOS Gesture Tracking Support)

/// Global frame cache for iOS gesture tracking support.
/// This provides a completely actor-free path for the Metal view to access frames.
/// During iOS gesture tracking (UITrackingRunLoopMode), accessing any @MainActor object
/// can cause synchronous waits that block the entire app. By using a global cache with
/// simple lock-based synchronization, the Metal view's draw loop can access frames
/// without any Swift concurrency overhead.
public final class MirageFrameCache: @unchecked Sendable {
    struct FrameEntry {
        let pixelBuffer: CVPixelBuffer
        let contentRect: CGRect
        let sequence: UInt64
        let decodeTime: CFAbsoluteTime
        let metalTexture: CVMetalTexture?
        let texture: MTLTexture?
    }

    /// Shared instance - use this from both decode callbacks and Metal views
    public static let shared = MirageFrameCache()

    private let lock = NSLock()
    private var frames: [StreamID: FrameEntry] = [:]

    private init() {}

    /// Store a frame for a stream (called from decode callback)
    public func store(
        _ pixelBuffer: CVPixelBuffer,
        contentRect: CGRect,
        metalTexture: CVMetalTexture?,
        texture: MTLTexture?,
        for streamID: StreamID
    ) {
        store(
            pixelBuffer,
            contentRect: contentRect,
            decodeTime: CFAbsoluteTimeGetCurrent(),
            metalTexture: metalTexture,
            texture: texture,
            for: streamID
        )
    }

    /// Store a frame with explicit decode time (for render timing diagnostics).
    public func store(
        _ pixelBuffer: CVPixelBuffer,
        contentRect: CGRect,
        decodeTime: CFAbsoluteTime,
        metalTexture: CVMetalTexture?,
        texture: MTLTexture?,
        for streamID: StreamID
    ) {
        lock.lock()
        let nextSequence = (frames[streamID]?.sequence ?? 0) &+ 1
        frames[streamID] = FrameEntry(
            pixelBuffer: pixelBuffer,
            contentRect: contentRect,
            sequence: nextSequence,
            decodeTime: decodeTime,
            metalTexture: metalTexture,
            texture: texture
        )
        lock.unlock()
    }

    /// Store a frame for a stream without a prebuilt Metal texture.
    public func store(_ pixelBuffer: CVPixelBuffer, contentRect: CGRect, for streamID: StreamID) {
        store(
            pixelBuffer,
            contentRect: contentRect,
            decodeTime: CFAbsoluteTimeGetCurrent(),
            metalTexture: nil,
            texture: nil,
            for: streamID
        )
    }

    func getEntry(for streamID: StreamID) -> FrameEntry? {
        lock.lock()
        let result = frames[streamID]
        lock.unlock()
        return result
    }

    /// Clear frame for a stream (called when stream ends)
    public func clear(for streamID: StreamID) {
        lock.lock()
        frames.removeValue(forKey: streamID)
        lock.unlock()
    }
}
