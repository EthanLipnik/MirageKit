//
//  MirageRenderStreamSnapshots.swift
//  MirageKitClientPresentation
//
//  Created by Ethan Lipnik on 6/5/26.
//

import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageKit
import MirageMedia
import MirageWire
import CoreMedia
import Foundation

package struct SubmissionSnapshot {
    /// Generation-aware cursor for presentation progress.
    ///
    /// A zero sequence records the current render generation before its first submission.
    package let cursor: MirageRenderCursor

    /// Last frame sequence accepted by the presentation layer.
    package let sequence: UInt64

    /// Wall-clock time when the frame was submitted.
    package let submittedTime: CFAbsoluteTime

    /// Host-provided presentation timestamp for the submitted frame, when available.
    package let remotePresentationTime: CMTime

    package init(
        cursor: MirageRenderCursor,
        sequence: UInt64,
        submittedTime: CFAbsoluteTime,
        remotePresentationTime: CMTime
    ) {
        self.cursor = cursor
        self.sequence = sequence
        self.submittedTime = submittedTime
        self.remotePresentationTime = remotePresentationTime
    }

    package func hasSubmittedFrame(after baseline: SubmissionSnapshot) -> Bool {
        cursor.hasSubmittedFrame && cursor.isAfter(baseline.cursor)
    }
}

package struct MirageRenderEnqueueResult {
    package let cursor: MirageRenderCursor
    package let didEnqueue: Bool
    package let pendingFrameCount: Int
    package let pendingFrameAgeMs: Double
    package let overwrittenPendingFrames: Int

    package init(
        cursor: MirageRenderCursor,
        didEnqueue: Bool,
        pendingFrameCount: Int,
        pendingFrameAgeMs: Double,
        overwrittenPendingFrames: Int
    ) {
        self.cursor = cursor
        self.didEnqueue = didEnqueue
        self.pendingFrameCount = pendingFrameCount
        self.pendingFrameAgeMs = pendingFrameAgeMs
        self.overwrittenPendingFrames = overwrittenPendingFrames
    }
}
