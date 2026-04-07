//
//  MirageHostService+UDP.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//

import Foundation
import MirageKit

#if os(macOS)
@MainActor
extension MirageHostService {
    func recordMediaPathSnapshot(
        streamID: StreamID,
        snapshot: MirageNetworkPathSnapshot,
        channel: String
    ) {
        let previous = mediaPathSnapshotByStreamID[streamID]
        mediaPathSnapshotByStreamID[streamID] = snapshot
        guard awdlExperimentEnabled else { return }
        guard let previous, previous.signature != snapshot.signature else { return }
        let switchText = "\(previous.kind.rawValue) -> \(snapshot.kind.rawValue)"
        MirageLogger.host("Media path switch (\(channel), stream \(streamID)): \(switchText)")
    }
}
#endif
