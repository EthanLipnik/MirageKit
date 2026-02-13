//
//  MirageClientService+State.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Stream state helpers and thread-safe snapshots.
//

import Foundation
import MirageKit

@MainActor
extension MirageClientService {
    func addActiveStreamID(_ id: StreamID) {
        activeStreamIDsLock.lock()
        activeStreamIDsStorage.insert(id)
        activeStreamIDsLock.unlock()
    }

    func removeActiveStreamID(_ id: StreamID) {
        activeStreamIDsLock.lock()
        activeStreamIDsStorage.remove(id)
        activeStreamIDsLock.unlock()
    }

    func clearAllActiveStreamIDs() {
        activeStreamIDsLock.lock()
        activeStreamIDsStorage.removeAll()
        activeStreamIDsLock.unlock()
    }

    /// Get a snapshot of reassemblers for thread-safe access from UDP callback.
    nonisolated func reassemblerForStream(_ id: StreamID) -> FrameReassembler? {
        reassemblersLock.lock()
        defer { reassemblersLock.unlock() }
        return reassemblersSnapshotStorage[id]
    }

    func updateReassemblerSnapshot() async {
        var snapshot: [StreamID: FrameReassembler] = [:]
        for (streamID, controller) in controllersByStream {
            snapshot[streamID] = await controller.getReassembler()
        }
        storeReassemblerSnapshot(snapshot)
    }

    private nonisolated func storeReassemblerSnapshot(_ snapshot: [StreamID: FrameReassembler]) {
        reassemblersLock.lock()
        reassemblersSnapshotStorage = snapshot
        reassemblersLock.unlock()
    }
}
