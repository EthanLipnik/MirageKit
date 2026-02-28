//
//  StreamPresentationTier.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/27/26.
//

import Foundation

public enum StreamPresentationTier: String, Codable, Sendable, Equatable {
    case activeLive
    case passiveSnapshot

    public var isActive: Bool {
        self == .activeLive
    }
}
