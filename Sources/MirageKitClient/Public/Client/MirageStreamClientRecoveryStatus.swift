//
//  MirageStreamClientRecoveryStatus.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/1/26.
//

import Foundation

/// High-level client-side recovery state for a live stream.
public enum MirageStreamClientRecoveryStatus: Sendable, Equatable {
    case idle
    case startup
    case tierPromotionProbe
    case keyframeRecovery
    case hardRecovery
    case postResizeAwaitingFirstFrame
}
