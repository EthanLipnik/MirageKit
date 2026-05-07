//
//  DecodeFrameTimingCache.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/6/26.
//

import CoreMedia
import Foundation

final class DecodeFrameTimingCache: @unchecked Sendable {
    struct Entry: Sendable, Equatable {
        let frameNumber: UInt32
        let remotePresentationTime: CMTime
    }

    private struct Key: Hashable {
        let value: CMTimeValue
        let timescale: CMTimeScale
        let flags: UInt32
        let epoch: CMTimeEpoch

        init(_ time: CMTime) {
            value = time.value
            timescale = time.timescale
            flags = time.flags.rawValue
            epoch = time.epoch
        }
    }

    private let lock = NSLock()
    private var entries: [Key: Entry] = [:]
    private var order: [Key] = []
    private let capacity: Int

    init(capacity: Int = 512) {
        self.capacity = max(1, capacity)
    }

    func insert(
        streamPresentationTime: CMTime,
        frameNumber: UInt32,
        remotePresentationTime: CMTime
    ) {
        let key = Key(streamPresentationTime)
        lock.lock()
        if entries[key] == nil {
            order.append(key)
        }
        entries[key] = Entry(frameNumber: frameNumber, remotePresentationTime: remotePresentationTime)
        trimLocked()
        lock.unlock()
    }

    func remove(streamPresentationTime: CMTime) -> Entry? {
        let key = Key(streamPresentationTime)
        lock.lock()
        let entry = entries.removeValue(forKey: key)
        if entry != nil {
            order.removeAll { $0 == key }
        }
        lock.unlock()
        return entry
    }

    func clear() {
        lock.lock()
        entries.removeAll(keepingCapacity: true)
        order.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    private func trimLocked() {
        while order.count > capacity {
            let key = order.removeFirst()
            entries.removeValue(forKey: key)
        }
    }
}
