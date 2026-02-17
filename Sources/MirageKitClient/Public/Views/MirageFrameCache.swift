//
//  MirageFrameCache.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/23/26.
//
//  Compatibility facade over the render stream store.
//

import CoreVideo
import Foundation
import Metal
import MirageKit

public final class MirageFrameCache: @unchecked Sendable {
    struct FrameEntry: @unchecked Sendable {
        let pixelBuffer: CVPixelBuffer
        let contentRect: CGRect
        let sequence: UInt64
        let decodeTime: CFAbsoluteTime
        let metalTexture: CVMetalTexture?
        let texture: MTLTexture?
    }

    struct EnqueueResult {
        let sequence: UInt64
        let queueDepth: Int
        let oldestAgeMs: Double
        let emergencyDrops: Int
    }

    struct PresentationSnapshot {
        let sequence: UInt64
        let presentedTime: CFAbsoluteTime
    }

    public static let shared = MirageFrameCache()

    private let store = MirageRenderStreamStore.shared

    private init() {}

    public func store(
        _ pixelBuffer: CVPixelBuffer,
        contentRect: CGRect,
        metalTexture: CVMetalTexture?,
        texture: MTLTexture?,
        for streamID: StreamID
    ) {
        _ = enqueue(
            pixelBuffer,
            contentRect: contentRect,
            decodeTime: CFAbsoluteTimeGetCurrent(),
            metalTexture: metalTexture,
            texture: texture,
            for: streamID
        )
    }

    @discardableResult
    func enqueue(
        _ pixelBuffer: CVPixelBuffer,
        contentRect: CGRect,
        decodeTime: CFAbsoluteTime,
        metalTexture: CVMetalTexture?,
        texture: MTLTexture?,
        for streamID: StreamID
    ) -> EnqueueResult {
        let result = store.enqueue(
            pixelBuffer: pixelBuffer,
            contentRect: contentRect,
            decodeTime: decodeTime,
            metalTexture: metalTexture,
            texture: texture,
            for: streamID
        )

        return EnqueueResult(
            sequence: result.sequence,
            queueDepth: result.queueDepth,
            oldestAgeMs: result.oldestAgeMs,
            emergencyDrops: result.emergencyDrops
        )
    }

    public func store(
        _ pixelBuffer: CVPixelBuffer,
        contentRect: CGRect,
        decodeTime: CFAbsoluteTime,
        metalTexture: CVMetalTexture?,
        texture: MTLTexture?,
        for streamID: StreamID
    ) {
        _ = enqueue(
            pixelBuffer,
            contentRect: contentRect,
            decodeTime: decodeTime,
            metalTexture: metalTexture,
            texture: texture,
            for: streamID
        )
    }

    public func store(_ pixelBuffer: CVPixelBuffer, contentRect: CGRect, for streamID: StreamID) {
        _ = enqueue(
            pixelBuffer,
            contentRect: contentRect,
            decodeTime: CFAbsoluteTimeGetCurrent(),
            metalTexture: nil,
            texture: nil,
            for: streamID
        )
    }

    func dequeue(for streamID: StreamID) -> FrameEntry? {
        guard let frame = store.dequeue(for: streamID) else { return nil }
        return frameEntry(from: frame)
    }

    func dequeueForPresentation(
        for streamID: StreamID,
        catchUpDepth: Int = 2,
        preferLatest: Bool = false
    ) -> FrameEntry? {
        guard let frame = store.dequeueForPresentation(
            for: streamID,
            catchUpDepth: catchUpDepth,
            preferLatest: preferLatest
        ) else {
            return nil
        }

        return frameEntry(from: frame)
    }

    func noteTypingBurstActivity(for streamID: StreamID) {
        store.noteTypingBurstActivity(for: streamID)
    }

    func isTypingBurstActive(for streamID: StreamID, now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) -> Bool {
        store.isTypingBurstActive(for: streamID, now: now)
    }

    func peekLatest(for streamID: StreamID) -> FrameEntry? {
        guard let frame = store.peekLatest(for: streamID) else { return nil }
        return frameEntry(from: frame)
    }

    func getEntry(for streamID: StreamID) -> FrameEntry? {
        peekLatest(for: streamID)
    }

    func queueDepth(for streamID: StreamID) -> Int {
        store.queueDepth(for: streamID)
    }

    func oldestAgeMs(for streamID: StreamID) -> Double {
        store.oldestAgeMs(for: streamID)
    }

    func latestSequence(for streamID: StreamID) -> UInt64 {
        store.latestSequence(for: streamID)
    }

    func markPresented(sequence: UInt64, for streamID: StreamID) {
        store.markPresented(sequence: sequence, for: streamID)
    }

    func presentationSnapshot(for streamID: StreamID) -> PresentationSnapshot {
        let snapshot = store.presentationSnapshot(for: streamID)
        return PresentationSnapshot(sequence: snapshot.sequence, presentedTime: snapshot.presentedTime)
    }

    public func clear(for streamID: StreamID) {
        store.clear(for: streamID)
    }

    private func frameEntry(from frame: MirageRenderFrame) -> FrameEntry {
        FrameEntry(
            pixelBuffer: frame.pixelBuffer,
            contentRect: frame.contentRect,
            sequence: frame.sequence,
            decodeTime: frame.decodeTime,
            metalTexture: frame.metalTexture,
            texture: frame.texture
        )
    }
}
