//
//  PacketBufferPool.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Reusable packet buffers for UDP send paths.
//

import Foundation

#if os(macOS)
final class PacketBufferPool: @unchecked Sendable {
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

        func prepareForReuse() {
            isReleased = false
            if data.count != capacity {
                data.count = capacity
            }
        }

        func prepare(length: Int) {
            let clampedLength = min(max(0, length), capacity)
            data.count = clampedLength
        }

        func finalize(length: Int) -> Data {
            let clampedLength = min(max(0, length), capacity)
            data.count = clampedLength
            return data
        }

        func withMutableBytes(_ body: (UnsafeMutableRawBufferPointer) -> Void) {
            data.withUnsafeMutableBytes(body)
        }

        func release() {
            guard !isReleased else { return }
            isReleased = true
            if data.count != capacity {
                data.count = capacity
            }
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

    func acquire() -> Buffer {
        lock.lock()
        if let buffer = buffers.popLast() {
            lock.unlock()
            buffer.prepareForReuse()
            return buffer
        }
        lock.unlock()
        let data = Data(count: capacity)
        let buffer = Buffer(capacity: capacity, data: data, pool: self)
        buffer.prepareForReuse()
        return buffer
    }

    fileprivate func reclaim(_ buffer: Buffer) {
        lock.lock()
        if buffers.count < maxBuffers {
            buffers.append(buffer)
            lock.unlock()
            return
        }
        lock.unlock()
    }
}
#endif
