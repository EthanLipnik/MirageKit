//
//  MirageRingBuffer.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/13/26.
//
//  Lock-friendly ring buffer for hot frame/decode queues.
//

import Foundation

/// FIFO ring buffer that keeps append/pop operations cheap for hot client queues.
struct MirageRingBuffer<Element> {
    private var storage: ContiguousArray<Element?>
    private var headIndex: Int = 0

    private(set) var count: Int = 0

    /// Creates a buffer with at least one storage slot.
    init(minimumCapacity: Int = 16) {
        let capacity = max(1, minimumCapacity)
        storage = ContiguousArray(repeating: nil, count: capacity)
    }

    var isEmpty: Bool {
        count < 1
    }

    /// Appends an element at the logical tail, growing storage when full.
    mutating func append(_ element: Element) {
        ensureCapacity(forAdditionalCount: 1)
        let tailIndex = index(offsetFromHead: count)
        storage[tailIndex] = element
        count += 1
    }

    /// Removes and returns the logical head element.
    mutating func popFirst() -> Element? {
        guard !isEmpty else { return nil }
        let element = storage[headIndex]
        storage[headIndex] = nil
        headIndex = (headIndex + 1) % storage.count
        count -= 1
        if isEmpty {
            headIndex = 0
        }
        return element
    }

    /// Removes all queued elements in FIFO order.
    mutating func drain() -> [Element] {
        guard !isEmpty else { return [] }
        var drained: [Element] = []
        drained.reserveCapacity(count)
        while let element = popFirst() {
            drained.append(element)
        }
        return drained
    }

    private func index(offsetFromHead offset: Int) -> Int {
        (headIndex + offset) % storage.count
    }

    private mutating func ensureCapacity(forAdditionalCount additionalCount: Int) {
        let required = count + additionalCount
        guard required > storage.count else { return }
        var newCapacity = storage.count
        while newCapacity < required {
            newCapacity = max(1, newCapacity * 2)
        }

        var newStorage = ContiguousArray<Element?>(repeating: nil, count: newCapacity)
        for itemOffset in 0 ..< count {
            newStorage[itemOffset] = storage[self.index(offsetFromHead: itemOffset)]
        }

        storage = newStorage
        headIndex = 0
    }
}
