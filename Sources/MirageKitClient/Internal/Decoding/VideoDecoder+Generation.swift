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

    func update(activeGeneration: UInt64) {
        lock.lock()
        self.activeGeneration = activeGeneration
        lock.unlock()
    }

    func currentGeneration() -> UInt64 {
        lock.lock()
        let generation = activeGeneration
        lock.unlock()
        return generation
    }
}

extension VideoDecoder {
    nonisolated static func shouldIgnoreDecodeCallback(
        callbackGeneration: UInt64,
        activeGeneration: UInt64
    ) -> Bool {
        callbackGeneration != activeGeneration
    }

    @discardableResult
    func advanceDecodeCallbackGeneration() -> UInt64 {
        decompressionSessionGeneration &+= 1
        decodeCallbackGenerationFence.update(activeGeneration: decompressionSessionGeneration)
        return decompressionSessionGeneration
    }

    func activeDecodeCallbackGeneration() -> UInt64 {
        decodeCallbackGenerationFence.currentGeneration()
    }
}
