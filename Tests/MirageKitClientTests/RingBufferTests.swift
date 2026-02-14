//
//  RingBufferTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/13/26.
//

@testable import MirageKitClient
import Testing

#if os(macOS)
@Suite("Ring Buffer")
struct RingBufferTests {
    @Test("Push and pop maintain FIFO ordering")
    func fifoOrdering() {
        var buffer = MirageRingBuffer<Int>(minimumCapacity: 2)
        buffer.append(1)
        buffer.append(2)
        buffer.append(3)

        #expect(buffer.count == 3)
        #expect(buffer.popFirst() == 1)
        #expect(buffer.popFirst() == 2)
        #expect(buffer.popFirst() == 3)
        #expect(buffer.popFirst() == nil)
    }

    @Test("Remove first trims without shifting entire storage")
    func removeFirstTrim() {
        var buffer = MirageRingBuffer<Int>(minimumCapacity: 4)
        for value in 0 ..< 6 {
            buffer.append(value)
        }

        let dropped = buffer.removeFirst(4)
        #expect(dropped == 4)
        #expect(buffer.count == 2)
        #expect(buffer.first == 4)
        #expect(buffer.last == 5)
    }

    @Test("Wrap-around preserves ordering")
    func wrapAroundOrdering() {
        var buffer = MirageRingBuffer<Int>(minimumCapacity: 4)
        for value in 0 ..< 4 {
            buffer.append(value)
        }
        #expect(buffer.popFirst() == 0)
        #expect(buffer.popFirst() == 1)

        buffer.append(4)
        buffer.append(5)

        #expect(buffer.count == 4)
        #expect(buffer.popFirst() == 2)
        #expect(buffer.popFirst() == 3)
        #expect(buffer.popFirst() == 4)
        #expect(buffer.popFirst() == 5)
    }

    @Test("Drain returns items in order and empties buffer")
    func drainEmptiesBuffer() {
        var buffer = MirageRingBuffer<Int>(minimumCapacity: 2)
        buffer.append(7)
        buffer.append(8)
        buffer.append(9)

        let drained = buffer.drain()

        #expect(drained == [7, 8, 9])
        #expect(buffer.count == 0)
        #expect(buffer.isEmpty)
    }
}
#endif
