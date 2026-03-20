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
        fastPathState.addActiveStreamID(id)
        updateRegistrationRefreshLoopState()
    }

    func removeActiveStreamID(_ id: StreamID) {
        fastPathState.removeActiveStreamID(id)
        updateRegistrationRefreshLoopState()
    }

    func clearAllActiveStreamIDs() {
        fastPathState.clearActiveStreamIDs()
        updateRegistrationRefreshLoopState()
    }

    func updateReassemblerSnapshot() async {
        var snapshot: [StreamID: FrameReassembler] = [:]
        for (streamID, controller) in controllersByStream {
            snapshot[streamID] = await controller.getReassembler()
        }
        storeReassemblerSnapshot(snapshot)
    }

    private nonisolated func storeReassemblerSnapshot(_ snapshot: [StreamID: FrameReassembler]) {
        fastPathState.setReassemblerSnapshot(snapshot)
    }

    func updateRegistrationRefreshLoopState() {
        // Registration refresh is no longer needed; media flows through Loom session streams.
        stopRegistrationRefreshLoop()
    }

    func stopRegistrationRefreshLoop() {
        registrationRefreshTask?.cancel()
        registrationRefreshTask = nil
    }
}
