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

/// Reuses large frame-reassembly buffers while returning finalized frame data as detached `Data`.
final class FrameBufferPool: @unchecked Sendable {
    nonisolated static let defaultMaxRetainedBufferCapacity = 16 * 1024 * 1024
    nonisolated static let defaultMaxRetainedBytes = 64 * 1024 * 1024

    /// Mutable byte storage leased from a `FrameBufferPool` for one frame assembly operation.
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

        /// Resets the buffer contents before a new owner writes packet payloads into it.
        func prepareForReuse() {
            isReleased = false
            if data.count != capacity { data.count = capacity }
            data.resetBytes(in: 0..<capacity)
        }

        /// Copies a packet payload into the leased buffer at the requested byte offset.
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

        /// Returns a detached copy of the first `length` bytes so reuse cannot mutate the frame output.
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

        /// Returns this buffer to the pool once the current assembly operation no longer needs it.
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

    /// Acquires zeroed storage with at least one byte of capacity.
    func acquire(capacity: Int) -> Buffer {
        let clampedCapacity = max(1, capacity)
        let reusableBuffer: Buffer?
        lock.lock()
        do {
            defer { lock.unlock() }
            if var buffers = buffersByCapacity[clampedCapacity], let buffer = buffers.popLast() {
                if buffers.isEmpty {
                    buffersByCapacity.removeValue(forKey: clampedCapacity)
                } else {
                    buffersByCapacity[clampedCapacity] = buffers
                }
                retainedBytes = max(0, retainedBytes - buffer.capacity)
                reusableBuffer = buffer
            } else {
                reusableBuffer = nil
            }
        }
        if let reusableBuffer {
            reusableBuffer.prepareForReuse()
            return reusableBuffer
        }

        let data = Data(count: clampedCapacity)
        let buffer = Buffer(capacity: clampedCapacity, data: data, pool: self)
        buffer.prepareForReuse()
        return buffer
    }

    /// Number of bytes currently held by retained, reusable buffers.
    var retainedByteCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return retainedBytes
    }

    /// Drops all retained buffers and returns the number of bytes released.
    func purgeRetainedBuffers() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let bytes = retainedBytes
        buffersByCapacity.removeAll(keepingCapacity: false)
        retainedBytes = 0
        return bytes
    }

    fileprivate func reclaim(_ buffer: Buffer) {
        guard buffer.capacity <= maxRetainedBufferCapacity else { return }

        lock.lock()
        defer { lock.unlock() }
        var buffers = buffersByCapacity[buffer.capacity] ?? []
        if buffers.count < maxBuffersPerCapacity {
            buffers.append(buffer)
            buffersByCapacity[buffer.capacity] = buffers
            retainedBytes += buffer.capacity
            trimRetainedBuffersIfNeeded()
        }
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
