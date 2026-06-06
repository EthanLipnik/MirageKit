//
//  IncomingMediaStreamKind.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/10/26.
//

import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageKit
import MirageKitClientPresentation
import MirageMedia
import MirageWire
import Foundation

/// Parsed kind for a Loom media stream label received by the client.
enum IncomingMediaStreamKind: Equatable {
    case video(StreamID)
    case audio(StreamID)
    case qualityTest(UUID)
    case transferData
    case unknown

    /// Classifies a Loom stream label into the Mirage receive loop that should own it.
    static func classify(label: String) -> IncomingMediaStreamKind {
        if label.hasPrefix("loom.transfer.data.") {
            return .transferData
        }

        if label.hasPrefix("video/") {
            let streamIDString = String(label.dropFirst("video/".count))
            guard let streamID = StreamID(streamIDString) else { return .unknown }
            return .video(streamID)
        }

        if label.hasPrefix("audio/") {
            let streamIDString = String(label.dropFirst("audio/".count))
            guard let streamID = StreamID(streamIDString) else { return .unknown }
            return .audio(streamID)
        }

        if label.hasPrefix("quality-test/") {
            let testIDString = String(label.dropFirst("quality-test/".count))
            guard let testID = UUID(uuidString: testIDString) else { return .unknown }
            return .qualityTest(testID)
        }

        return .unknown
    }
}

