//
//  StreamController+Constants.swift
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

extension StreamController {
    /// Time window for counting repeated decode failures before escalating recovery.
    static let decodeRecoveryEscalationWindow: CFAbsoluteTime = 8.0
    /// Number of decode-threshold recoveries inside the escalation window that triggers a full reset.
    static let decodeRecoveryEscalationThreshold: Int = 3

    /// Duration without decoded frame presentation progress before recovery is requested.
    static let freezeTimeout: CFAbsoluteTime = 1.25
    /// Pending render frame age after which keyframe-starved streams should stop trying presenter recovery.
    static let stalePendingRenderFrameRecoveryAgeMs: Double = 250
    /// Delay before memory-pressure recovery asks for a replacement keyframe.
    static let memoryBudgetRecoveryDelay: Duration = .milliseconds(500)

    /// Interval for checking freeze state.
    static let freezeCheckInterval: Duration = .milliseconds(250)
    /// Cooldown between freeze-triggered recovery attempts.
    static let freezeRecoveryCooldown: CFAbsoluteTime = 3.0
    /// Grace period for a presenter-only freeze probe to submit a newer frame.
    static let freezePresenterProbeGrace: CFAbsoluteTime = 0.5
    /// Number of repeated freeze recoveries before escalating the recovery path.
    static let freezeRecoveryEscalationThreshold: Int = 2

    /// Maximum number of compressed frames buffered ahead of decode.
    static let maxQueuedFrames: Int = 15
    /// Maximum compressed frame bytes retained for AWDL radio before dependency recovery.
    static let awdlMaxQueuedFrameBytes: Int = 32 * 1024 * 1024
    /// Lower frame-count bound for the AWDL radio pre-decode jitter buffer.
    static let awdlMinQueuedFrames: Int = 8
    /// Upper frame-count bound for the AWDL radio pre-decode jitter buffer.
    static let awdlMaxQueuedFrameCap: Int = 30
    /// Poll interval while waiting for the first presented frame after startup/reset/resize.
    static let firstPresentedFramePollInterval: Duration = .milliseconds(8)
    /// Interval for progress logs while waiting on first-frame presentation.
    static let firstPresentedFrameWaitLogInterval: CFAbsoluteTime = 0.5
    /// Grace period before issuing bootstrap recovery while initial startup has no presentation progress.
    static let startupFirstPresentedFrameBootstrapRecoveryGrace: CFAbsoluteTime = 5.0
    /// Grace period before a first-frame startup stall escalates to a full pipeline reset.
    static let startupFirstPresentedFrameHardRecoveryGrace: CFAbsoluteTime = 15.0
    /// Grace period before issuing bootstrap recovery after an established stream is reset.
    static let recoveryFirstPresentedFrameBootstrapRecoveryGrace: CFAbsoluteTime = 1.0
    /// Grace period before a reset/recovery first-frame stall escalates again.
    static let recoveryFirstPresentedFrameHardRecoveryGrace: CFAbsoluteTime = 3.0
    /// Cooldown between bootstrap recovery probes while awaiting the first presented frame.
    static let firstPresentedFrameRecoveryCooldown: CFAbsoluteTime = 1.0
    /// Escalate to a hard recovery after a single bounded bootstrap request stalls again.
    static let firstPresentedFrameHardRecoveryThreshold: Int = 2
    /// Maximum number of startup hard recoveries before the stream is failed terminally.
    static let startupHardRecoveryLimit: Int = 1

    /// Minimum interval between decode backpressure drop logs.
    static let queueDropLogInterval: CFAbsoluteTime = 1.0
    /// Minimum interval between decode backpressure diagnostic logs.
    static let backpressureLogCooldown: CFAbsoluteTime = 1.0
    /// Minimum interval between recovery request dispatches.
    static let recoveryRequestDispatchCooldown: CFAbsoluteTime = 0.5
    /// Minimum interval between background decode-error logs.
    static let backgroundDecodeErrorLogInterval: CFAbsoluteTime = 2.0
    /// Minimum interval between repeated foreground decode-error logs.
    static let decodeErrorLogInterval: CFAbsoluteTime = 15.0
    /// Consecutive foreground decode errors required before logging and recovery escalation.
    static let decodeErrorEscalationThreshold: Int = 3
    /// Grace interval after resize before decode-error recovery can fire.
    static let postResizeDecodeErrorGraceInterval: CFAbsoluteTime = 0.75
    /// Consecutive successful post-resize decodes required to clear decode gating.
    static let postResizeDecodeRecoverySuccessThreshold: Int = 3
    /// Highest decode-submission concurrency limit allowed for one stream.
    static let decodeSubmissionMaximumLimit: Int = 3
    /// Ratio below which decode submission is treated as stressed.
    static let decodeSubmissionStressThreshold: Double = 0.80
    /// Ratio above which decode submission is treated as healthy.
    static let decodeSubmissionHealthyThreshold: Double = 0.95
    /// Number of stressed reporting windows before lowering decode submission pressure.
    static let decodeSubmissionStressWindows: Int = 2
    /// Number of healthy reporting windows before relaxing decode submission pressure.
    static let decodeSubmissionHealthyWindows: Int = 3
    /// FPS gap that marks the decoder as the likely cadence limiter.
    static let decodeSubmissionDecodeBoundGapFPS: Double = 2.5
    /// FPS gap that marks the source as the likely cadence limiter.
    static let decodeSubmissionSourceBoundGapFPS: Double = 1.0

    static func awdlMaxQueuedFrames(targetFPS: Int) -> Int {
        let targetFPS = max(1, targetFPS)
        let frames = Int(
            (Double(targetFPS) * MirageAwdlMediaController.decodeQueueWindowMs / 1_000.0)
                .rounded(.up)
        )
        return min(awdlMaxQueuedFrameCap, max(awdlMinQueuedFrames, frames))
    }
}
