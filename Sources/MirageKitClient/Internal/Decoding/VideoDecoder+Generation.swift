//
//  VideoDecoder+Generation.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/15/26.
//
//  Decoder generation fencing helpers.
//

import Foundation

final class DecodeCallbackGenerationFence: @unchecked Sendable {
    private let lock = NSLock()
    private var activeGeneration: UInt64 = 0

    /// Publishes the generation that decode callbacks must match to be accepted.
    func update(activeGeneration: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        self.activeGeneration = activeGeneration
    }

    /// Returns the currently accepted decode callback generation.
    var currentGeneration: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return activeGeneration
    }
}

extension VideoDecoder {
    /// Returns whether a callback belongs to a decompression session that has since been replaced.
    nonisolated static func shouldIgnoreDecodeCallback(
        callbackGeneration: UInt64,
        activeGeneration: UInt64
    ) -> Bool {
        callbackGeneration != activeGeneration
    }

    /// Advances the generation after creating a new decompression session.
    func advanceDecodeCallbackGeneration() -> UInt64 {
        decompressionSessionGeneration &+= 1
        decodeCallbackGenerationFence.update(activeGeneration: decompressionSessionGeneration)
        return decompressionSessionGeneration
    }

    /// Invalidates all callbacks that may still arrive from an old decompression session.
    func invalidateDecodeCallbacks() {
        decompressionSessionGeneration &+= 1
        decodeCallbackGenerationFence.update(activeGeneration: decompressionSessionGeneration)
    }
}
