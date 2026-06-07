//
//  MirageForegroundStreamHealthSnapshot.swift
//  MirageDiagnostics
//
//  Created by Ethan Lipnik on 6/5/26.
//

import Foundation
import MirageCore

/// Lightweight snapshot of a foreground stream's receiver health.
public struct MirageForegroundStreamHealthSnapshot: Sendable, Equatable {
    /// Stream being sampled.
    public let streamID: StreamID

    /// Whether the stream still has an active controller.
    public let hasController: Bool

    /// Whether the stream still has an attached video media stream.
    public let hasVideoMediaStream: Bool

    /// Last observed packet time in absolute seconds.
    public let latestPacketTime: CFAbsoluteTime

    /// Latest submitted packet sequence observed by the receiver.
    public let submittedSequence: UInt64

    /// Wall-clock time for the latest submitted frame.
    public let submittedTime: CFAbsoluteTime

    /// Unique visible frame submissions observed over the current telemetry window.
    public let visibleFrameFPS: Double

    /// Number of frames currently queued for presentation.
    public let pendingFrameCount: Int

    /// Age of the oldest pending presentation frame in milliseconds.
    public let pendingFrameAgeMs: Double

    /// Whether decode cadence is healthy relative to the stream target.
    public let decodeHealthy: Bool

    /// Whether the receiver is waiting for a keyframe before decoding can continue.
    public let isAwaitingKeyframe: Bool

    /// Creates a foreground stream health snapshot.
    public init(
        streamID: StreamID,
        hasController: Bool,
        hasVideoMediaStream: Bool,
        latestPacketTime: CFAbsoluteTime,
        submittedSequence: UInt64,
        submittedTime: CFAbsoluteTime = 0,
        visibleFrameFPS: Double = 0,
        pendingFrameCount: Int = 0,
        pendingFrameAgeMs: Double = 0,
        decodeHealthy: Bool = true,
        isAwaitingKeyframe: Bool
    ) {
        self.streamID = streamID
        self.hasController = hasController
        self.hasVideoMediaStream = hasVideoMediaStream
        self.latestPacketTime = latestPacketTime
        self.submittedSequence = submittedSequence
        self.submittedTime = submittedTime
        self.visibleFrameFPS = visibleFrameFPS
        self.pendingFrameCount = pendingFrameCount
        self.pendingFrameAgeMs = pendingFrameAgeMs
        self.decodeHealthy = decodeHealthy
        self.isAwaitingKeyframe = isAwaitingKeyframe
    }
}
