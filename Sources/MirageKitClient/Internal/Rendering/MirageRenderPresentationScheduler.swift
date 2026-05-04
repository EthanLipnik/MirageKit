//
//  MirageRenderPresentationScheduler.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/12/26.
//

import Foundation
import MirageKit
import QuartzCore

enum MirageRenderSubmissionResult: Equatable, Sendable {
    case submitted
    case noPendingFrame
    case displayLayerNotReady
    case blocked
}

@MainActor
final class MirageRenderPresentationScheduler {
    private let referenceTimeProvider: () -> CFTimeInterval
    private let enqueueCoalescedPass: (@escaping @MainActor () -> Void) -> Void
    private let submit: @MainActor (CFTimeInterval) -> MirageRenderSubmissionResult
    private let hasPendingFrame: @MainActor () -> Bool
    private let onDisplayLayerNotReady: @MainActor () -> Void

    private var streamID: StreamID?
    private var presentationTier: StreamPresentationTier = .activeLive
    private var renderingSuspended = false

    private var scheduledPassPending = false
    private var scheduledPassGeneration: UInt64 = 0
    private var scheduledReferenceTime: CFTimeInterval?
    private var runningPass = false
    private var pendingScheduledPass = false

    init(
        referenceTimeProvider: @escaping () -> CFTimeInterval = CACurrentMediaTime,
        enqueueCoalescedPass: @escaping (@escaping @MainActor () -> Void) -> Void = { action in
            Task { @MainActor in
                await Task.yield()
                action()
            }
        },
        submit: @escaping @MainActor (CFTimeInterval) -> MirageRenderSubmissionResult,
        hasPendingFrame: @escaping @MainActor () -> Bool = { false },
        onDisplayLayerNotReady: @escaping @MainActor () -> Void = {}
    ) {
        self.referenceTimeProvider = referenceTimeProvider
        self.enqueueCoalescedPass = enqueueCoalescedPass
        self.submit = submit
        self.hasPendingFrame = hasPendingFrame
        self.onDisplayLayerNotReady = onDisplayLayerNotReady
    }

    func setStreamID(_ streamID: StreamID?) {
        if self.streamID != streamID {
            reset()
        }
        self.streamID = streamID
    }

    func setPresentationTier(_ tier: StreamPresentationTier) {
        presentationTier = tier
    }

    func setRenderingSuspended(_ suspended: Bool) {
        renderingSuspended = suspended
        if suspended {
            reset()
        }
    }

    func reset() {
        scheduledPassPending = false
        scheduledPassGeneration &+= 1
        scheduledReferenceTime = nil
        runningPass = false
        pendingScheduledPass = false
    }

    func requestImmediateSubmission(referenceTime: CFTimeInterval) {
        guard !renderingSuspended else { return }
        performPass(referenceTime: referenceTime, allowFollowUpSchedule: shouldAllowFollowUpScheduling)
    }

    func requestReadinessRetry(referenceTime: CFTimeInterval) {
        guard !renderingSuspended else { return }
        schedulePass(referenceTime: referenceTime)
    }

    func handleFrameAvailable(referenceTime: CFTimeInterval) {
        guard !renderingSuspended else { return }

        if shouldUseCoalescedFrameArrivalSubmission {
            schedulePass(referenceTime: referenceTime)
            return
        }

        performPass(referenceTime: referenceTime, allowFollowUpSchedule: shouldAllowFollowUpScheduling)
    }

    private var shouldUseCoalescedFrameArrivalSubmission: Bool {
        presentationTier == .activeLive
    }

    private var shouldAllowFollowUpScheduling: Bool {
        presentationTier == .activeLive
    }

    private func schedulePass(referenceTime: CFTimeInterval) {
        if let scheduledReferenceTime {
            self.scheduledReferenceTime = max(scheduledReferenceTime, referenceTime)
        } else {
            scheduledReferenceTime = referenceTime
        }

        guard !scheduledPassPending else { return }
        scheduledPassPending = true
        let generation = scheduledPassGeneration
        enqueueCoalescedPass { [weak self] in
            guard let self else { return }
            guard self.scheduledPassGeneration == generation else { return }
            self.scheduledPassPending = false
            self.runScheduledPass()
        }
    }

    private func runScheduledPass() {
        let referenceTime = scheduledReferenceTime ?? referenceTimeProvider()
        scheduledReferenceTime = nil
        performPass(referenceTime: referenceTime, allowFollowUpSchedule: shouldAllowFollowUpScheduling)
    }

    private func performPass(
        referenceTime: CFTimeInterval,
        allowFollowUpSchedule: Bool
    ) {
        guard streamID != nil else { return }

        if runningPass {
            pendingScheduledPass = true
            schedulePass(referenceTime: referenceTime)
            return
        }

        runningPass = true
        let submissionResult = submit(referenceTime)
        runningPass = false
        if submissionResult == .displayLayerNotReady {
            onDisplayLayerNotReady()
        }

        if pendingScheduledPass {
            pendingScheduledPass = false
            schedulePass(referenceTime: referenceTimeProvider())
            return
        }

        guard allowFollowUpSchedule, submissionResult == .submitted, hasPendingFrame() else { return }
        schedulePass(referenceTime: referenceTimeProvider())
    }
}
