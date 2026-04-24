//
//  MirageHostService+StreamSetupCancellation.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/24/26.
//

import Foundation
import MirageKit

#if os(macOS)
@MainActor
extension MirageHostService {
    struct StreamSetupCancellationKey: Hashable {
        let clientSessionID: UUID
        let startupRequestID: UUID
    }

    func beginStreamSetup(
        clientSessionID: UUID,
        startupRequestID: UUID
    ) {
        cancelledStreamSetupRequestIDs.remove(StreamSetupCancellationKey(
            clientSessionID: clientSessionID,
            startupRequestID: startupRequestID
        ))
    }

    func cancelStreamSetup(
        clientSessionID: UUID,
        startupRequestID: UUID
    ) {
        cancelledStreamSetupRequestIDs.insert(StreamSetupCancellationKey(
            clientSessionID: clientSessionID,
            startupRequestID: startupRequestID
        ))
    }

    func isStreamSetupCancelled(
        clientSessionID: UUID,
        startupRequestID: UUID
    ) -> Bool {
        cancelledStreamSetupRequestIDs.contains(StreamSetupCancellationKey(
            clientSessionID: clientSessionID,
            startupRequestID: startupRequestID
        ))
    }

    func finishStreamSetup(
        clientSessionID: UUID,
        startupRequestID: UUID
    ) {
        cancelledStreamSetupRequestIDs.remove(StreamSetupCancellationKey(
            clientSessionID: clientSessionID,
            startupRequestID: startupRequestID
        ))
    }
}
#endif
