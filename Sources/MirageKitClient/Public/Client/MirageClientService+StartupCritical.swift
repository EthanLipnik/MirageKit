//
//  MirageClientService+StartupCritical.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/26/26.
//

import Foundation
import MirageKit

@MainActor
extension MirageClientService {
    private func setStartupCriticalSectionActive(_ active: Bool) {
        guard startupCriticalSectionActive != active else { return }
        startupCriticalSectionActive = active
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.onStartupCriticalSectionChanged?(active)
        }
    }

    func beginConnectionStartupCriticalSection() {
        startupCriticalIdleReleaseTask?.cancel()
        setStartupCriticalSectionActive(true)
    }

    func armConnectionStartupIdleRelease() {
        startupCriticalIdleReleaseTask?.cancel()
        startupCriticalIdleReleaseTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: startupCriticalIdleGrace)
            guard self.pendingStartupCriticalStreamIDs.isEmpty else { return }
            self.setStartupCriticalSectionActive(false)
        }
    }

    func beginStreamStartupCriticalSection(streamID: StreamID) {
        startupCriticalIdleReleaseTask?.cancel()
        pendingStartupCriticalStreamIDs.insert(streamID)
        setStartupCriticalSectionActive(true)
    }

    func completeStreamStartupCriticalSection(streamID: StreamID) {
        pendingStartupCriticalStreamIDs.remove(streamID)
        if pendingStartupCriticalStreamIDs.isEmpty {
            setStartupCriticalSectionActive(false)
        }
    }

    func clearStartupCriticalSection() {
        startupCriticalIdleReleaseTask?.cancel()
        startupCriticalIdleReleaseTask = nil
        pendingStartupCriticalStreamIDs.removeAll()
        setStartupCriticalSectionActive(false)
    }
}
