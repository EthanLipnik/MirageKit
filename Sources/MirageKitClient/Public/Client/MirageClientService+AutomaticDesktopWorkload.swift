//
//  MirageClientService+AutomaticDesktopWorkload.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/12/26.
//
//  Client-driven automatic desktop workload reconfiguration.
//

import Foundation
import MirageKit

@MainActor
extension MirageClientService {
    /// Requests a host-side desktop workload tier change for the active desktop stream.
    public func requestAutomaticDesktopWorkloadReconfiguration(
        streamID: StreamID,
        target: MirageAutomaticDesktopWorkloadTier
    )
    async throws -> Bool {
        guard case .connected = connectionState else { throw MirageError.protocolError("Not connected") }
        MirageLogger.client(
            "Ignoring automatic desktop workload reconfiguration for stream \(streamID): " +
                "\(target.logLabel); adaptive recovery does not change resolution or capture FPS"
        )
        return false
    }
}
