//
//  FrameBufferPool.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Reusable frame buffers for packet reassembly.
//

import Foundation

final class FrameBufferPool: @unchecked Sendable {
    final class Buffer: @unchecked Sendable {
        private let pool: FrameBufferPool
        let capacity: Int
        private var data: Data
        private var isReleased = false

        init(capacity: Int, data: Data, pool: FrameBufferPool) {
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

        func write(_ payload: Data, at offset: Int) {
            guard offset >= 0, offset + payload.count <= capacity else { return }
            data.withUnsafeMutableBytes { destination in
                guard let destinationBase = destination.baseAddress else { return }
                payload.withUnsafeBytes { source in
                    guard let sourceBase = source.baseAddress else { return }
                    destinationBase.advanced(by: offset).copyMemory(from: sourceBase, byteCount: payload.count)
                }
            }
        }

        func finalize(length: Int) -> Data {
            let clampedLength = min(max(0, length), capacity)
            data.count = clampedLength
            return data
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

    private let lock = NSLock()
    private let maxBuffersPerCapacity: Int
    private var buffersByCapacity: [Int: [Buffer]] = [:]

    init(maxBuffersPerCapacity: Int = 4) {
        self.maxBuffersPerCapacity = max(1, maxBuffersPerCapacity)
    }

    func acquire(capacity: Int) -> Buffer {
        let clampedCapacity = max(1, capacity)
        lock.lock()
        if var buffers = buffersByCapacity[clampedCapacity], let buffer = buffers.popLast() {
            buffersByCapacity[clampedCapacity] = buffers
            lock.unlock()
            buffer.prepareForReuse()
            return buffer
        }
        lock.unlock()
        let data = Data(count: clampedCapacity)
        let buffer = Buffer(capacity: clampedCapacity, data: data, pool: self)
        buffer.prepareForReuse()
        return buffer
    }

    fileprivate func reclaim(_ buffer: Buffer) {
        lock.lock()
        var buffers = buffersByCapacity[buffer.capacity] ?? []
        if buffers.count < maxBuffersPerCapacity {
            buffers.append(buffer)
            buffersByCapacity[buffer.capacity] = buffers
            lock.unlock()
            return
        }
        lock.unlock()
    }
}
