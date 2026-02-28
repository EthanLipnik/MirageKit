//
//  ClientStreamScheduler.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/27/26.
//

import Foundation
import MirageKit

actor ClientStreamScheduler {
    private var activeStreamID: StreamID?

    func resolveTiers(
        streamIDs: [StreamID],
        preferredActiveStreamID: StreamID?
    ) -> [StreamID: StreamPresentationTier] {
        let ordered = Array(Set(streamIDs)).sorted()
        guard !ordered.isEmpty else {
            activeStreamID = nil
            return [:]
        }

        if let preferredActiveStreamID,
           ordered.contains(preferredActiveStreamID) {
            activeStreamID = preferredActiveStreamID
        } else if let currentActive = activeStreamID,
                  ordered.contains(currentActive) {
            activeStreamID = currentActive
        } else {
            activeStreamID = ordered.first
        }

        guard let activeStreamID else {
            return Dictionary(uniqueKeysWithValues: ordered.map { ($0, .passiveSnapshot) })
        }

        var result: [StreamID: StreamPresentationTier] = [:]
        result.reserveCapacity(ordered.count)
        for streamID in ordered {
            result[streamID] = streamID == activeStreamID ? .activeLive : .passiveSnapshot
        }
        return result
    }
}
