//
//  DecodeFrameTimingCache.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/6/26.
//

import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageKit
import MirageKitClientPresentation
import MirageMedia
import MirageWire
import CoreMedia
import Foundation

/// Thread-safe bounded cache mapping client presentation timestamps back to host timestamps.
final class DecodeFrameTimingCache: @unchecked Sendable {
    /// Remote timing metadata retained until the renderer consumes a presented frame.
    struct Entry: Sendable {
        /// Presentation timestamp originally supplied by the host.
        let remotePresentationTime: CMTime
        let frameNumber: UInt32?
        let hostEpoch: UInt16?
        let dimensionToken: UInt16?
        let queueEpoch: UInt64?
        let renderGeneration: UInt64?
    }

    /// Hashable representation of `CMTime` that preserves the fields used for equality.
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

    /// Stores the host timestamp for a client presentation timestamp.
    func insert(
        streamPresentationTime: CMTime,
        remotePresentationTime: CMTime,
        frameNumber: UInt32? = nil,
        hostEpoch: UInt16? = nil,
        dimensionToken: UInt16? = nil,
        queueEpoch: UInt64? = nil,
        renderGeneration: UInt64? = nil
    ) {
        let key = Key(streamPresentationTime)
        lock.lock()
        defer { lock.unlock() }
        if entries[key] == nil {
            order.append(key)
        }
        entries[key] = Entry(
            remotePresentationTime: remotePresentationTime,
            frameNumber: frameNumber,
            hostEpoch: hostEpoch,
            dimensionToken: dimensionToken,
            queueEpoch: queueEpoch,
            renderGeneration: renderGeneration
        )
        trimLocked()
    }

    /// Removes timing metadata once the presentation pipeline reports the matching timestamp.
    func remove(streamPresentationTime: CMTime) -> Entry? {
        let key = Key(streamPresentationTime)
        lock.lock()
        defer { lock.unlock() }
        let entry = entries.removeValue(forKey: key)
        if entry != nil {
            order.removeAll { $0 == key }
        }
        return entry
    }

    /// Drops all cached timing metadata, usually after stream reset or teardown.
    func clear() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll(keepingCapacity: true)
        order.removeAll(keepingCapacity: true)
    }

    private func trimLocked() {
        while order.count > capacity {
            let key = order.removeFirst()
            entries.removeValue(forKey: key)
        }
    }
}
