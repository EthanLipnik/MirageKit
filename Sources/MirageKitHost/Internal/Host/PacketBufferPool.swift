//
//  PacketBufferPool.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Reusable packet buffers for UDP send paths.
//

import Foundation
import MirageKit

#if os(macOS)
/// Fixed-capacity packet buffer pool used by host send paths to reduce per-packet allocation churn.
final class PacketBufferPool: @unchecked Sendable {
    /// Mutable packet storage leased for one send operation.
    final class Buffer: @unchecked Sendable {
        private let pool: PacketBufferPool
        private let capacity: Int
        private var data: Data
        private var isReleased = false

        init(capacity: Int, data: Data, pool: PacketBufferPool) {
            self.capacity = capacity
            self.data = data
            self.pool = pool
        }

        /// Restores the backing storage to full capacity before the next send operation writes into it.
        func prepareForReuse() {
            isReleased = false
            if data.count != capacity { data.count = capacity }
        }

        /// Resizes the visible packet payload before callers fill the buffer.
        func prepare(length: Int) {
            let clampedLength = min(max(0, length), capacity)
            data.count = clampedLength
        }

        /// Returns the visible packet payload for immediate send use.
        func finalize(length: Int) -> Data {
            let clampedLength = min(max(0, length), capacity)
            data.count = clampedLength
            return data
        }

        /// Provides mutable access to the packet bytes while the buffer is leased.
        func withMutableBytes(_ body: (UnsafeMutableRawBufferPointer) -> Void) {
            data.withUnsafeMutableBytes(body)
        }

        /// Returns this buffer to the pool after the packet send no longer needs it.
        func release() {
            guard !isReleased else { return }
            isReleased = true
            if data.count != capacity { data.count = capacity }
            pool.reclaim(self)
        }
    }

    private let capacity: Int
    private let maxBuffers: Int
    private let lock = NSLock()
    private var buffers: [Buffer] = []

    init(capacity: Int, maxBuffers: Int = 256) {
        self.capacity = max(1, capacity)
        self.maxBuffers = max(1, maxBuffers)
    }

    /// Acquires a reusable packet buffer at the pool's fixed capacity.
    func acquire() -> Buffer {
        let reusableBuffer: Buffer?
        lock.lock()
        do {
            defer { lock.unlock() }
            reusableBuffer = buffers.popLast()
        }
        if let reusableBuffer {
            reusableBuffer.prepareForReuse()
            return reusableBuffer
        }

        let data = Data(count: capacity)
        let buffer = Buffer(capacity: capacity, data: data, pool: self)
        buffer.prepareForReuse()
        return buffer
    }

    fileprivate func reclaim(_ buffer: Buffer) {
        lock.lock()
        defer { lock.unlock() }
        if buffers.count < maxBuffers {
            buffers.append(buffer)
        }
    }
}
#endif
