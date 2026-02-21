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
        updateRegistrationRefreshLoopState()
    }

    func removeActiveStreamID(_ id: StreamID) {
        activeStreamIDsLock.lock()
        activeStreamIDsStorage.remove(id)
        activeStreamIDsLock.unlock()
        updateRegistrationRefreshLoopState()
    }

    func clearAllActiveStreamIDs() {
        activeStreamIDsLock.lock()
        activeStreamIDsStorage.removeAll()
        activeStreamIDsLock.unlock()
        updateRegistrationRefreshLoopState()
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

    func updateRegistrationRefreshLoopState() {
        let hasActiveStreams = !activeStreamIDsForFiltering.isEmpty
        let isConnected: Bool
        if case .connected = connectionState {
            isConnected = true
        } else {
            isConnected = false
        }
        guard Self.shouldRunRegistrationRefreshLoop(
            experimentEnabled: awdlExperimentEnabled,
            hasActiveStreams: hasActiveStreams,
            isConnected: isConnected
        ) else {
            stopRegistrationRefreshLoop()
            return
        }
        startRegistrationRefreshLoopIfNeeded()
    }

    nonisolated static func shouldRunRegistrationRefreshLoop(
        experimentEnabled: Bool,
        hasActiveStreams: Bool,
        isConnected: Bool
    ) -> Bool {
        experimentEnabled && hasActiveStreams && isConnected
    }

    private func startRegistrationRefreshLoopIfNeeded() {
        guard registrationRefreshTask == nil else { return }
        registrationRefreshTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let jitter = UInt64.random(in: 0 ... registrationRefreshJitterMs)
                let sleepMs = registrationRefreshIntervalMs + jitter
                try? await Task.sleep(for: .milliseconds(Int64(sleepMs)))
                if Task.isCancelled { return }
                await refreshTransportRegistrations(reason: "periodic-refresh", triggerKeyframe: false)
            }
        }
    }

    func stopRegistrationRefreshLoop() {
        registrationRefreshTask?.cancel()
        registrationRefreshTask = nil
    }
}
