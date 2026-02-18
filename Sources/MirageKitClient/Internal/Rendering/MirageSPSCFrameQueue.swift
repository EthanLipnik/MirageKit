//
//  MirageSPSCFrameQueue.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/16/26.
//
//  Stream-local ring buffer for decoded frames.
//

import Foundation

final class MirageSPSCFrameQueue: @unchecked Sendable {
    struct Snapshot: Sendable {
        let depth: Int
        let oldestDecodeTime: CFAbsoluteTime?
        let latestSequence: UInt64
    }

    private var storage: [MirageRenderFrame?]
    private var head: Int = 0
    private var tail: Int = 0
    private var count: Int = 0
    private(set) var capacity: Int

    init(capacity: Int) {
        let normalizedCapacity = max(1, capacity)
        self.capacity = normalizedCapacity
        storage = Array(repeating: nil, count: normalizedCapacity)
    }

    func enqueue(_ frame: MirageRenderFrame) -> (dropped: Int, depth: Int) {
        var dropped = 0

        if count == capacity {
            storage[head] = nil
            head = indexAfter(head)
            count -= 1
            dropped = 1
        }

        storage[tail] = frame
        tail = indexAfter(tail)
        count += 1
        return (dropped: dropped, depth: count)
    }

    func dequeue() -> MirageRenderFrame? {
        guard count > 0, let frame = storage[head] else {
            return nil
        }

        storage[head] = nil
        head = indexAfter(head)
        count -= 1
        return frame
    }

    func trimNewest(keepDepth: Int) -> Int {
        let clampedKeepDepth = max(1, keepDepth)
        guard count > clampedKeepDepth else {
            return 0
        }

        let dropCount = count - clampedKeepDepth
        for _ in 0 ..< dropCount {
            storage[head] = nil
            head = indexAfter(head)
            count -= 1
        }
        return dropCount
    }

    func snapshot() -> Snapshot {
        let depth = count
        let oldest = depth > 0 ? storage[head]?.decodeTime : nil
        var latestSequence: UInt64 = 0
        if depth > 0 {
            let latestIndex = normalizedIndex(tail - 1)
            latestSequence = storage[latestIndex]?.sequence ?? 0
        }

        return Snapshot(
            depth: depth,
            oldestDecodeTime: oldest,
            latestSequence: latestSequence
        )
    }

    func peekLatest() -> MirageRenderFrame? {
        guard count > 0 else { return nil }
        let latestIndex = normalizedIndex(tail - 1)
        return storage[latestIndex]
    }

    func clear() {
        storage = Array(repeating: nil, count: capacity)
        head = 0
        tail = 0
        count = 0
    }

    private func indexAfter(_ index: Int) -> Int {
        let next = index + 1
        return next == capacity ? 0 : next
    }

    private func normalizedIndex(_ value: Int) -> Int {
        if value >= 0 {
            return value % capacity
        }
        let remainder = value % capacity
        return remainder == 0 ? 0 : remainder + capacity
    }
}
