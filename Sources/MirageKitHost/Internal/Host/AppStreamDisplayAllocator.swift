//
//  AppStreamDisplayAllocator.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/27/26.
//

import Foundation
import MirageKit

#if os(macOS)
actor AppStreamDisplayAllocator {
    enum Slot: String, Sendable, CaseIterable {
        case liveDisplay
        case snapshotDisplay
    }

    struct AllocationSnapshot: Sendable {
        var liveStreamID: StreamID?
        var snapshotStreamID: StreamID?
    }

    private var snapshot = AllocationSnapshot()

    func bindLive(streamID: StreamID) {
        snapshot.liveStreamID = streamID
    }

    func bindSnapshot(streamID: StreamID?) {
        snapshot.snapshotStreamID = streamID
    }

    func unbind(streamID: StreamID) {
        if snapshot.liveStreamID == streamID {
            snapshot.liveStreamID = nil
        }
        if snapshot.snapshotStreamID == streamID {
            snapshot.snapshotStreamID = nil
        }
    }

    func currentSnapshot() -> AllocationSnapshot {
        snapshot
    }

    nonisolated static var maximumDisplayCount: Int { Slot.allCases.count }
}
#endif
