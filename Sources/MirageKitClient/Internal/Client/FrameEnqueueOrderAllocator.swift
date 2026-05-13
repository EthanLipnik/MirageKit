//
//  FrameEnqueueOrderAllocator.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/9/26.
//

import Foundation

final class FrameEnqueueOrderAllocator: @unchecked Sendable {
    private let lock = NSLock()
    private var nextOrder: UInt64 = 0

    func allocate() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        let order = nextOrder
        nextOrder &+= 1
        return order
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        nextOrder = 0
    }
}
