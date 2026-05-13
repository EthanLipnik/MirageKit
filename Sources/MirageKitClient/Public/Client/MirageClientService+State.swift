//
//  MirageClientService+State.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Stream state helpers and thread-safe snapshots.
//

import MirageKit

@MainActor
extension MirageClientService {
    /// Stream IDs readable from nonisolated media fast paths.
    nonisolated var activeStreamIDsForFiltering: Set<StreamID> {
        fastPathState.activeStreamIDs
    }

    /// Stream IDs that currently participate in interactive playback and receive runtime encoder-setting updates.
    public var activeInteractiveStreamIDs: [StreamID] {
        var streamIDs: [StreamID] = []
        if let desktopStreamID {
            streamIDs.append(desktopStreamID)
        }
        streamIDs.append(contentsOf: activeStreams.map(\.id))

        var seen = Set<StreamID>()
        return streamIDs.filter { seen.insert($0).inserted }
    }

    /// Publishes the current controller reassemblers to the fast-path packet ingress snapshot.
    func updateReassemblerSnapshot() async {
        var snapshot: [StreamID: FrameReassembler] = [:]
        for (streamID, controller) in controllersByStream {
            snapshot[streamID] = controller.reassembler
        }
        fastPathState.setReassemblerSnapshot(snapshot)
    }
}
