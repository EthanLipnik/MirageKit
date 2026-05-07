//
//  DecodeCallbackFailureLogLimiter.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/7/26.
//

import Foundation

final class DecodeCallbackFailureLogLimiter: @unchecked Sendable {
    struct Decision: Sendable, Equatable {
        let shouldLog: Bool
        let suppressedCount: UInt64
    }

    private struct Entry {
        var lastLogTime: CFAbsoluteTime
        var suppressedCount: UInt64
    }

    private let lock = NSLock()
    private let interval: CFAbsoluteTime
    private var entries: [OSStatus: Entry] = [:]

    init(interval: CFAbsoluteTime = 1.0) {
        self.interval = max(0, interval)
    }

    func record(status: OSStatus, now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) -> Decision {
        lock.lock()
        defer { lock.unlock() }

        var entry = entries[status] ?? Entry(lastLogTime: -.greatestFiniteMagnitude, suppressedCount: 0)
        if now - entry.lastLogTime >= interval {
            let suppressedCount = entry.suppressedCount
            entry.lastLogTime = now
            entry.suppressedCount = 0
            entries[status] = entry
            return Decision(shouldLog: true, suppressedCount: suppressedCount)
        }

        entry.suppressedCount += 1
        entries[status] = entry
        return Decision(shouldLog: false, suppressedCount: 0)
    }

    func reset() {
        lock.lock()
        entries.removeAll(keepingCapacity: true)
        lock.unlock()
    }
}
