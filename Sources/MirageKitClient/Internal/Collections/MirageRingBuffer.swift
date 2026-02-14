//
//  MirageRingBuffer.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/13/26.
//
//  Lock-friendly ring buffer for hot frame/decode queues.
//

import Foundation

struct MirageRingBuffer<Element> {
    private var storage: ContiguousArray<Element?>
    private var headIndex: Int = 0

    private(set) var count: Int = 0

    init(minimumCapacity: Int = 16) {
        let capacity = max(1, minimumCapacity)
        storage = ContiguousArray(repeating: nil, count: capacity)
    }

    var isEmpty: Bool {
        count == 0
    }

    var first: Element? {
        guard count > 0 else { return nil }
        return storage[headIndex]
    }

    var last: Element? {
        guard count > 0 else { return nil }
        let tailIndex = index(offsetFromHead: count - 1)
        return storage[tailIndex]
    }

    mutating func append(_ element: Element) {
        ensureCapacity(forAdditionalCount: 1)
        let tailIndex = index(offsetFromHead: count)
        storage[tailIndex] = element
        count += 1
    }

    @discardableResult
    mutating func popFirst() -> Element? {
        guard count > 0 else { return nil }
        let element = storage[headIndex]
        storage[headIndex] = nil
        headIndex = (headIndex + 1) % storage.count
        count -= 1
        if count == 0 {
            headIndex = 0
        }
        return element
    }

    @discardableResult
    mutating func removeFirst(_ amount: Int) -> Int {
        guard amount > 0, count > 0 else { return 0 }
        let dropCount = min(amount, count)
        for _ in 0 ..< dropCount {
            storage[headIndex] = nil
            headIndex = (headIndex + 1) % storage.count
        }
        count -= dropCount
        if count == 0 {
            headIndex = 0
        }
        return dropCount
    }

    mutating func removeAll(keepingCapacity: Bool) {
        if keepingCapacity {
            _ = removeFirst(count)
            return
        }
        storage = ContiguousArray(repeating: nil, count: 1)
        headIndex = 0
        count = 0
    }

    mutating func drain() -> [Element] {
        guard count > 0 else { return [] }
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
