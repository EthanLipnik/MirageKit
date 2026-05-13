//
//  MirageHostService+Maintenance.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/4/26.
//
//  Host maintenance helpers for virtual display recovery.
//

import MirageKit

#if os(macOS)
extension MirageHostService {
    /// Resets the shared virtual display identity when no host streams are active.
    public func resetVirtualDisplayIdentity() async throws {
        if !activeStreams.isEmpty || desktopStreamContext != nil {
            throw MirageError.protocolError("Stop streaming before resetting the virtual display identity.")
        }

        try await SharedVirtualDisplayManager.shared.resetVirtualDisplayIdentity()
    }
}
#endif
