//
//  MessageTypes+Keyframe.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Message type definitions.
//

import Foundation

// MARK: - Keyframe Messages

package struct KeyframeRequestMessage: Codable {
    package let streamID: StreamID

    package init(streamID: StreamID) {
        self.streamID = streamID
    }
}
