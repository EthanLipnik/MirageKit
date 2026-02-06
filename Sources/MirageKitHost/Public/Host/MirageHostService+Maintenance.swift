//
//  MirageHostService+Maintenance.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/4/26.
//
//  Host maintenance helpers for virtual display recovery.
//

import Foundation
import MirageKit

#if os(macOS)
extension MirageHostService {
    public func resetVirtualDisplayIdentity() async throws {
        if !activeStreams.isEmpty || desktopStreamContext != nil || loginDisplayContext != nil {
            throw MirageError.protocolError("Stop streaming before resetting the virtual display identity.")
        }

        try await SharedVirtualDisplayManager.shared.resetVirtualDisplayIdentity()
    }
}
#endif
