//
//  MirageClientStreamOptions.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/4/26.
//

import Foundation

/// Controls where the client surfaces its in-stream settings gear while streaming.
public enum MirageStreamOptionsDisplayMode: String, CaseIterable, Codable, Sendable {
    case inStream
    case hostMenuBar

    public var displayName: String {
        switch self {
        case .inStream:
            "In Stream"
        case .hostMenuBar:
            "Host Menu Bar"
        }
    }
}
