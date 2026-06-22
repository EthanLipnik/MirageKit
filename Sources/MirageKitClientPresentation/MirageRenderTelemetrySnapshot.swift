//
//  MirageRenderTelemetrySnapshot.swift
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
import Foundation

/// Rolling render telemetry sampled by stream UI and diagnostics.
package struct RenderTelemetrySnapshot {
    /// Display clock ticks observed during the one-second telemetry window.
    package let displayTickFPS: Double

    /// Presentation attempts made during the one-second telemetry window.
    package let submitAttemptFPS: Double

    /// Frames accepted by the display layer during the one-second telemetry window.
    package let layerAcceptedFPS: Double

    /// Unique frame submissions accepted by the display layer during the one-second telemetry window.
    package let visibleFrameFPS: Double

    /// Total display-layer submissions during the one-second telemetry window.
    package let submittedFPS: Double

    /// Unique frame submissions, excluding repeated ticks that reused the last frame.
    package let uniqueSubmittedFPS: Double

    /// Frames currently queued for presentation.
    package let pendingFrameCount: Int

    /// Age of the oldest pending frame in milliseconds.
    package let pendingFrameAgeMs: Double

    /// 95th percentile age of the oldest pending frame in the telemetry window.
    package let pendingFrameAgeP95Ms: Double

    /// Maximum age of the oldest pending frame in the telemetry window.
    package let pendingFrameAgeMaxMs: Double

    /// Maximum queued frame depth sampled in the telemetry window.
    package let pendingFrameDepthMax: Int

    /// Current Smoothest-mode display debt, in milliseconds.
    package let smoothestDisplayDebtMs: Double

    /// Active Smoothest-mode display debt cap, in milliseconds.
    package let smoothestDisplayDebtCapMs: Double

    /// Current Smoothest-mode target playout delay, in milliseconds.
    package let smoothestTargetDelayMs: Double

    /// Pending frames overwritten because the local playout queue was full.
    package let overwrittenPendingFrames: UInt64

    /// Smoothest-mode frames dropped by local playout queue bounds.
    package let smoothestQueueDrops: UInt64

    /// Smoothest-mode frames dropped because the queue exceeded its depth bound.
    package let smoothestDepthDrops: UInt64

    /// Smoothest-mode frames dropped because queued frames exceeded the stale-age bound.
    package let smoothestAgeDrops: UInt64

    /// Smoothest-mode frames dropped while younger than 100 ms.
    package let smoothestDropsUnder100ms: UInt64

    /// Maximum local age for a Smoothest-mode dropped frame.
    package let smoothestDroppedFrameAgeMaxMs: Double

    /// Smoothest-mode frames dropped because queued display debt exceeded the live threshold.
    package let smoothestDisplayDebtDrops: UInt64

    /// Number of Smoothest-mode FIFO resets caused by stale or excessive display debt.
    package let smoothestFifoResetCount: UInt64

    /// Queued frames dropped because newer frames had already superseded them.
    package let lateFrameDrops: UInt64

    /// Frames coalesced before presentation.
    package let coalescedBeforeSubmitCount: UInt64

    /// Frames received with a duplicate host presentation timestamp.
    package let duplicateRemoteTimestampCount: UInt64

    /// Frames whose host timestamp required local monotonic correction.
    package let correctedStreamTimestampCount: UInt64

    /// Times presentation was attempted while the display layer was not ready.
    package let displayLayerNotReadyCount: UInt64

    /// Display ticks that repeated the previous submitted frame.
    package let repeatedFrameCount: UInt64

    package let displayTickNoFrameCount: UInt64
    package let pendingFrameNotReadyDisplayTickCount: UInt64
    package let frameArrivedAfterNoFrameTickCount: UInt64
    package let frameArrivalFallbackCount: UInt64
    package let frameArrivalFallbackScheduledCount: UInt64
    package let frameArrivalFallbackSubmittedCount: UInt64
    package let noFrameTickToFrameArrivalMaxMs: Double

    /// Display intervals that exceeded the target frame duration threshold.
    package let missedVSyncCount: UInt64

    /// 95th percentile display-clock interval in milliseconds.
    package let displayTickIntervalP95Ms: Double

    /// 99th percentile display-clock interval in milliseconds.
    package let displayTickIntervalP99Ms: Double

    /// Current playout delay target in frames.
    package let playoutDelayFrames: Int

    /// Presentation gaps counted as stalls since the previous snapshot.
    package let presentationStallCount: UInt64

    /// Longest presentation gap in milliseconds since the previous snapshot.
    package let worstPresentationGapMs: Double

    /// 95th percentile unique-frame submission interval in milliseconds.
    package let frameIntervalP95Ms: Double

    /// 99th percentile unique-frame submission interval in milliseconds.
    package let frameIntervalP99Ms: Double

    /// Whether decode throughput is high enough for the current source frame rate.
    package let decodeHealthy: Bool

    package init(
        displayTickFPS: Double,
        submitAttemptFPS: Double,
        layerAcceptedFPS: Double,
        visibleFrameFPS: Double,
        submittedFPS: Double,
        uniqueSubmittedFPS: Double,
        pendingFrameCount: Int,
        pendingFrameAgeMs: Double,
        pendingFrameAgeP95Ms: Double,
        pendingFrameAgeMaxMs: Double,
        pendingFrameDepthMax: Int,
        smoothestDisplayDebtMs: Double,
        smoothestDisplayDebtCapMs: Double,
        smoothestTargetDelayMs: Double,
        overwrittenPendingFrames: UInt64,
        smoothestQueueDrops: UInt64,
        smoothestDepthDrops: UInt64,
        smoothestAgeDrops: UInt64,
        smoothestDropsUnder100ms: UInt64,
        smoothestDroppedFrameAgeMaxMs: Double,
        smoothestDisplayDebtDrops: UInt64,
        smoothestFifoResetCount: UInt64,
        lateFrameDrops: UInt64,
        coalescedBeforeSubmitCount: UInt64,
        duplicateRemoteTimestampCount: UInt64,
        correctedStreamTimestampCount: UInt64,
        displayLayerNotReadyCount: UInt64,
        repeatedFrameCount: UInt64,
        displayTickNoFrameCount: UInt64,
        pendingFrameNotReadyDisplayTickCount: UInt64,
        frameArrivedAfterNoFrameTickCount: UInt64,
        frameArrivalFallbackCount: UInt64,
        frameArrivalFallbackScheduledCount: UInt64,
        frameArrivalFallbackSubmittedCount: UInt64,
        noFrameTickToFrameArrivalMaxMs: Double,
        missedVSyncCount: UInt64,
        displayTickIntervalP95Ms: Double,
        displayTickIntervalP99Ms: Double,
        playoutDelayFrames: Int,
        presentationStallCount: UInt64,
        worstPresentationGapMs: Double,
        frameIntervalP95Ms: Double,
        frameIntervalP99Ms: Double,
        decodeHealthy: Bool
    ) {
        self.displayTickFPS = displayTickFPS
        self.submitAttemptFPS = submitAttemptFPS
        self.layerAcceptedFPS = layerAcceptedFPS
        self.visibleFrameFPS = visibleFrameFPS
        self.submittedFPS = submittedFPS
        self.uniqueSubmittedFPS = uniqueSubmittedFPS
        self.pendingFrameCount = pendingFrameCount
        self.pendingFrameAgeMs = pendingFrameAgeMs
        self.pendingFrameAgeP95Ms = pendingFrameAgeP95Ms
        self.pendingFrameAgeMaxMs = pendingFrameAgeMaxMs
        self.pendingFrameDepthMax = pendingFrameDepthMax
        self.smoothestDisplayDebtMs = smoothestDisplayDebtMs
        self.smoothestDisplayDebtCapMs = smoothestDisplayDebtCapMs
        self.smoothestTargetDelayMs = smoothestTargetDelayMs
        self.overwrittenPendingFrames = overwrittenPendingFrames
        self.smoothestQueueDrops = smoothestQueueDrops
        self.smoothestDepthDrops = smoothestDepthDrops
        self.smoothestAgeDrops = smoothestAgeDrops
        self.smoothestDropsUnder100ms = smoothestDropsUnder100ms
        self.smoothestDroppedFrameAgeMaxMs = smoothestDroppedFrameAgeMaxMs
        self.smoothestDisplayDebtDrops = smoothestDisplayDebtDrops
        self.smoothestFifoResetCount = smoothestFifoResetCount
        self.lateFrameDrops = lateFrameDrops
        self.coalescedBeforeSubmitCount = coalescedBeforeSubmitCount
        self.duplicateRemoteTimestampCount = duplicateRemoteTimestampCount
        self.correctedStreamTimestampCount = correctedStreamTimestampCount
        self.displayLayerNotReadyCount = displayLayerNotReadyCount
        self.repeatedFrameCount = repeatedFrameCount
        self.displayTickNoFrameCount = displayTickNoFrameCount
        self.pendingFrameNotReadyDisplayTickCount = pendingFrameNotReadyDisplayTickCount
        self.frameArrivedAfterNoFrameTickCount = frameArrivedAfterNoFrameTickCount
        self.frameArrivalFallbackCount = frameArrivalFallbackCount
        self.frameArrivalFallbackScheduledCount = frameArrivalFallbackScheduledCount
        self.frameArrivalFallbackSubmittedCount = frameArrivalFallbackSubmittedCount
        self.noFrameTickToFrameArrivalMaxMs = noFrameTickToFrameArrivalMaxMs
        self.missedVSyncCount = missedVSyncCount
        self.displayTickIntervalP95Ms = displayTickIntervalP95Ms
        self.displayTickIntervalP99Ms = displayTickIntervalP99Ms
        self.playoutDelayFrames = playoutDelayFrames
        self.presentationStallCount = presentationStallCount
        self.worstPresentationGapMs = worstPresentationGapMs
        self.frameIntervalP95Ms = frameIntervalP95Ms
        self.frameIntervalP99Ms = frameIntervalP99Ms
        self.decodeHealthy = decodeHealthy
    }
}
