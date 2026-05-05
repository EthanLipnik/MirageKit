//
//  FrameBufferPoolTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/4/26.
//
//  Regression coverage for pooled frame-buffer reuse safety.
//

@testable import MirageKitClient
import Foundation
import Testing

#if os(macOS)
@Suite("Frame Buffer Pool")
struct FrameBufferPoolTests {
    @Test("Finalized frames are detached from pooled storage reuse")
    func finalizedFramesRemainStableAfterBufferReuse() {
        let pool = FrameBufferPool(maxBuffersPerCapacity: 1)

        let firstBuffer = pool.acquire(capacity: 8)
        firstBuffer.write(Data([0x01, 0x02, 0x03, 0x04]), at: 0)
        let firstOutput = firstBuffer.finalize(length: 4)
        firstBuffer.release()

        let secondBuffer = pool.acquire(capacity: 8)
        secondBuffer.write(Data([0xAA, 0xBB, 0xCC, 0xDD]), at: 0)
        let secondOutput = secondBuffer.finalize(length: 4)
        secondBuffer.release()

        #expect(firstOutput == Data([0x01, 0x02, 0x03, 0x04]))
        #expect(secondOutput == Data([0xAA, 0xBB, 0xCC, 0xDD]))
        #expect(firstOutput != secondOutput)
    }

    @Test("Oversized buffers are not retained")
    func oversizedBuffersAreNotRetained() {
        let pool = FrameBufferPool(
            maxBuffersPerCapacity: 4,
            maxRetainedBufferCapacity: 16,
            maxRetainedBytes: 64
        )

        let oversizedBuffer = pool.acquire(capacity: 32)
        oversizedBuffer.release()

        #expect(pool.retainedByteCount() == 0)
    }

    @Test("Retained buffers stay under total byte budget")
    func retainedBuffersStayUnderTotalByteBudget() {
        let pool = FrameBufferPool(
            maxBuffersPerCapacity: 4,
            maxRetainedBufferCapacity: 16,
            maxRetainedBytes: 24
        )

        let firstBuffer = pool.acquire(capacity: 16)
        let secondBuffer = pool.acquire(capacity: 16)
        firstBuffer.release()
        secondBuffer.release()

        #expect(pool.retainedByteCount() <= 24)

        let reusedBuffer = pool.acquire(capacity: 16)
        #expect(pool.retainedByteCount() == 0)
        reusedBuffer.release()
    }
}
#endif
