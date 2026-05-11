//
//  FrameBufferPool.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Reusable frame buffers for packet reassembly.
//

import Foundation
import MirageKit

final class FrameBufferPool: @unchecked Sendable {
    nonisolated static let defaultMaxRetainedBufferCapacity = 16 * 1024 * 1024
    nonisolated static let defaultMaxRetainedBytes = 64 * 1024 * 1024

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
            if data.count != capacity { data.count = capacity }
            data.resetBytes(in: 0..<capacity)
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
            guard clampedLength > 0 else {
                return Data()
            }

            return data.withUnsafeBytes { buffer in
                guard let baseAddress = buffer.baseAddress else {
                    return Data()
                }
                return Data(bytes: baseAddress, count: clampedLength)
            }
        }

        func withUnsafeBytes(_ body: (UnsafeRawBufferPointer) -> Void) {
            data.withUnsafeBytes { buffer in
                body(buffer)
            }
        }

        func release() {
            guard !isReleased else { return }
            isReleased = true
            if data.count != capacity { data.count = capacity }
            pool.reclaim(self)
        }
    }

    private let lock = NSLock()
    private let maxBuffersPerCapacity: Int
    private let maxRetainedBufferCapacity: Int
    private let maxRetainedBytes: Int
    private var buffersByCapacity: [Int: [Buffer]] = [:]
    private var retainedBytes = 0

    init(
        maxBuffersPerCapacity: Int = 4,
        maxRetainedBufferCapacity: Int = FrameBufferPool.defaultMaxRetainedBufferCapacity,
        maxRetainedBytes: Int = FrameBufferPool.defaultMaxRetainedBytes
    ) {
        self.maxBuffersPerCapacity = max(1, maxBuffersPerCapacity)
        self.maxRetainedBufferCapacity = max(1, maxRetainedBufferCapacity)
        self.maxRetainedBytes = max(1, maxRetainedBytes)
    }

    func acquire(capacity: Int) -> Buffer {
        let clampedCapacity = max(1, capacity)
        lock.lock()
        if var buffers = buffersByCapacity[clampedCapacity], let buffer = buffers.popLast() {
            if buffers.isEmpty {
                buffersByCapacity.removeValue(forKey: clampedCapacity)
            } else {
                buffersByCapacity[clampedCapacity] = buffers
            }
            retainedBytes = max(0, retainedBytes - buffer.capacity)
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

    func retainedByteCount() -> Int {
        lock.lock()
        let bytes = retainedBytes
        lock.unlock()
        return bytes
    }

    func purgeRetainedBuffers() -> Int {
        lock.lock()
        let bytes = retainedBytes
        buffersByCapacity.removeAll(keepingCapacity: false)
        retainedBytes = 0
        lock.unlock()
        return bytes
    }

    fileprivate func reclaim(_ buffer: Buffer) {
        guard buffer.capacity <= maxRetainedBufferCapacity else { return }

        lock.lock()
        var buffers = buffersByCapacity[buffer.capacity] ?? []
        if buffers.count < maxBuffersPerCapacity {
            buffers.append(buffer)
            buffersByCapacity[buffer.capacity] = buffers
            retainedBytes += buffer.capacity
            trimRetainedBuffersIfNeeded()
            lock.unlock()
            return
        }
        lock.unlock()
    }

    private func trimRetainedBuffersIfNeeded() {
        while retainedBytes > maxRetainedBytes {
            guard let capacity = buffersByCapacity.keys.max(),
                  var buffers = buffersByCapacity[capacity],
                  let buffer = buffers.popLast()
            else {
                retainedBytes = 0
                return
            }

            retainedBytes = max(0, retainedBytes - buffer.capacity)
            if buffers.isEmpty {
                buffersByCapacity.removeValue(forKey: capacity)
            } else {
                buffersByCapacity[capacity] = buffers
            }
        }
    }
}
