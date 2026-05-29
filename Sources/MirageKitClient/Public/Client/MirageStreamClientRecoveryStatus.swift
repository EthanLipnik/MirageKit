//
//  MirageStreamClientRecoveryStatus.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/1/26.
//

/// High-level client-side recovery state for a live stream.
public enum MirageStreamClientRecoveryStatus: Sendable, Equatable {
    /// No recovery action is active.
    case idle
    /// Initial stream startup is waiting for stable media.
    case startup
    /// Client is probing whether the stream can move to a higher presentation tier.
    case tierPromotionProbe
    /// Client has requested or is waiting for a recovery keyframe.
    case keyframeRecovery
    /// Client is rebuilding the decode path after a serious stream failure.
    case hardRecovery
    /// Desktop resize completed and the client is waiting for the first matching frame.
    case postResizeAwaitingFirstFrame
}

/// Client-side cause for the active recovery state reported to the host.
public enum MirageStreamClientRecoveryCause: Sendable, Equatable {
    /// No active recovery cause is known.
    case none
    /// Recovery was triggered by repeated decoder errors.
    case decodeError
    /// Recovery was triggered by missing frames or incomplete reassembly.
    case frameLoss
    /// Recovery was triggered by a visible presentation freeze.
    case freezeTimeout
    /// Recovery was triggered by a local memory or frame-buffer budget event.
    case memoryBudget
    /// Startup timed out while waiting for the first usable frame.
    case startupTimeout
    /// Recovery was triggered manually or by a lifecycle action without a narrower cause.
    case manual
}
