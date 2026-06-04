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

    /// Logical stream IDs that currently participate in interactive playback.
    public var activeInteractiveStreamIDs: [StreamID] {
        var streamIDs: [StreamID] = []
        if let desktopStreamID {
            streamIDs.append(desktopStreamID)
        }
        streamIDs.append(contentsOf: activeStreams.map(\.id))

        var seen = Set<StreamID>()
        return streamIDs.filter { seen.insert($0).inserted }
    }

    /// Physical media stream IDs that should receive runtime quality and encoder cadence updates.
    public var activeRuntimeQualityMediaStreamIDs: [StreamID] {
        var streamIDs: [StreamID] = []
        if let desktopStreamID {
            streamIDs.append(desktopStreamID)
        }
        streamIDs.append(contentsOf: activeStreams.map(\.mediaStreamID))
        streamIDs.append(contentsOf: activeSessionsOrderedByLogicalStreamID.map(\.mediaStreamID))
        return Self.deDuplicatedStreamIDs(streamIDs)
    }

    /// Physical media stream IDs that can safely receive runtime stream-scale changes.
    public var activeRuntimeScalableStreamIDs: [StreamID] {
        let appAtlasMediaStreamIDs = Set(
            activeSessionsOrderedByLogicalStreamID.compactMap { session in
                session.streamID == session.mediaStreamID ? nil : session.mediaStreamID
            }
        )
        return activeRuntimeQualityMediaStreamIDs.filter { !appAtlasMediaStreamIDs.contains($0) }
    }

    /// Logical stream IDs currently presented by the client.
    public var activePresentationStreamIDs: [StreamID] {
        var streamIDs: [StreamID] = []
        if let desktopStreamID {
            streamIDs.append(desktopStreamID)
        }
        streamIDs.append(contentsOf: activeStreams.map(\.id))
        streamIDs.append(contentsOf: activeSessionsOrderedByLogicalStreamID.map(\.streamID))
        return Self.deDuplicatedStreamIDs(streamIDs)
    }

    /// Resolves a logical stream ID to the physical media stream that carries runtime quality state.
    public func runtimeQualityMediaStreamID(for streamID: StreamID) -> StreamID? {
        if desktopStreamID == streamID {
            return streamID
        }
        if let session = activeStreams.first(where: { $0.id == streamID || $0.mediaStreamID == streamID }) {
            return session.mediaStreamID
        }
        if let session = activeSessionsOrderedByLogicalStreamID.first(where: {
            $0.streamID == streamID || $0.mediaStreamID == streamID
        }) {
            return session.mediaStreamID
        }
        return nil
    }

    /// Publishes the current controller reassemblers to the fast-path packet ingress snapshot.
    func updateReassemblerSnapshot() async {
        var snapshot: [StreamID: FrameReassembler] = [:]
        for (streamID, controller) in controllersByStream {
            snapshot[streamID] = controller.reassembler
        }
        fastPathState.setReassemblerSnapshot(snapshot)
    }

    private static func deDuplicatedStreamIDs(_ streamIDs: [StreamID]) -> [StreamID] {
        var seen = Set<StreamID>()
        return streamIDs.filter { seen.insert($0).inserted }
    }

    private var activeSessionsOrderedByLogicalStreamID: [MirageStreamSessionState] {
        sessionStore.activeSessions.sorted { lhs, rhs in
            lhs.streamID < rhs.streamID
        }
    }
}
