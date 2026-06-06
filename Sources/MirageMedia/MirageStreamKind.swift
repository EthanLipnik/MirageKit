//
//  MirageStreamKind.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 6/5/26.
//

import Foundation

/// Broad stream family used by MirageKit surfaces and session metadata.
public enum MirageStreamKind: Hashable, Sendable, Codable {
    /// Stream captures a host application window.
    case app

    /// Stream captures a host desktop or virtual display.
    case desktop

    /// Stream is supplied by application-defined custom media.
    case custom
}
