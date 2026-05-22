//
//  CaptureStreamOutputTypes.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/9/26.
//
//  Capture stream telemetry and stall state carriers.
//

import Foundation

#if os(macOS)
extension CaptureStreamOutput {
    enum KeyframeRequestReason {
        case fallbackResume
    }

    enum StallStage: String {
        case soft
        case hard
        case resumed
    }

    struct StallSignal {
        let stage: StallStage
        let message: String
        let gapMs: String
        let softThresholdMs: String
        let hardThresholdMs: String
        let restartEligible: Bool
    }

    struct TelemetrySnapshot: Equatable {
        let sampleDurationSeconds: Double
        let rawScreenCallbackCount: UInt64
        let validScreenSampleCount: UInt64
        let renderableScreenSampleCount: UInt64
        let completeFrameCount: UInt64
        let idleFrameCount: UInt64
        let blankFrameCount: UInt64
        let suspendedFrameCount: UInt64
        let startedFrameCount: UInt64
        let stoppedFrameCount: UInt64
        let cadenceAdmittedFrameCount: UInt64
        let deliveredFrameCount: UInt64
        let callbackDurationTotalMs: Double
        let callbackDurationMaxMs: Double
        let callbackSampleCount: UInt64
        let cadenceDropCount: UInt64
        let admissionDropCount: UInt64
        let cadenceMetrics: CaptureCadenceMetricsSnapshot

        var rawScreenCallbackFPS: Double? {
            rate(for: rawScreenCallbackCount)
        }

        var completeFrameFPS: Double? {
            rate(for: completeFrameCount)
        }

        var renderableFrameFPS: Double? {
            rate(for: renderableScreenSampleCount)
        }

        var cadenceAdmittedFrameFPS: Double? {
            rate(for: cadenceAdmittedFrameCount)
        }

        /// SCK delivery rate used for post-capture validation.
        ///
        /// Complete frames are the signal that the keepalive is actually dirtying the captured display.
        /// Renderable/idle counts are still tracked separately for diagnostics.
        var observedSCKFPS: Double? {
            completeFrameFPS
        }

        private func rate(for count: UInt64) -> Double? {
            guard sampleDurationSeconds >= 0.75 else { return nil }
            return Double(count) / sampleDurationSeconds
        }
    }

    struct CadenceDecision: Equatable {
        let shouldDrop: Bool
        let originPresentationTime: Double?
        let admittedSlotIndex: Int64
        let expectedPresentationTime: Double?
    }

    struct CaptureStartupReadinessState {
        var hasObservedSample = false
        var hasUsableFrame = false
        var hasIdleFrame = false
        var blankOrSuspendedCount: UInt64 = 0
        var hasLoggedBlankOrSuspended = false
        var hasLoggedLifecycleSample = false

        var readiness: DisplayCaptureStartupReadiness {
            if hasUsableFrame { return .usableFrameSeen }
            if hasIdleFrame { return .idleFrameSeen }
            if blankOrSuspendedCount > 0 { return .blankOrSuspendedOnly }
            return .noScreenSamples
        }
    }
}
#endif
