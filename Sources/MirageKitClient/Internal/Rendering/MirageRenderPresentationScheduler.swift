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
    private var displayClockActive = false
    private var displayClockFramePending = false

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

    func setDisplayClockActive(_ active: Bool) {
        guard displayClockActive != active else { return }
        displayClockActive = active
        displayClockFramePending = false
        if active {
            scheduledPassPending = false
            scheduledPassGeneration &+= 1
            scheduledReferenceTime = nil
        }
    }

    func reset() {
        scheduledPassPending = false
        scheduledPassGeneration &+= 1
        scheduledReferenceTime = nil
        runningPass = false
        pendingScheduledPass = false
        displayClockFramePending = false
    }

    func requestImmediateSubmission(referenceTime: CFTimeInterval) {
        guard !renderingSuspended else { return }
        if presentationTier == .activeLive {
            if hasPendingFrame() {
                displayClockFramePending = true
            }
            return
        }
        _ = performPass(
            referenceTime: referenceTime,
            allowFollowUpSchedule: shouldAllowFollowUpScheduling,
            isDisplayTick: false
        )
    }

    func requestReadinessRetry(referenceTime: CFTimeInterval) {
        guard !renderingSuspended else { return }
        if presentationTier == .activeLive {
            displayClockFramePending = true
            return
        }
        schedulePass(referenceTime: referenceTime)
    }

    func handleFrameAvailable(referenceTime: CFTimeInterval) {
        guard !renderingSuspended else { return }

        if presentationTier == .activeLive {
            displayClockFramePending = true
            return
        }

        if shouldUseCoalescedFrameArrivalSubmission {
            schedulePass(referenceTime: referenceTime)
            return
        }

        _ = performPass(referenceTime: referenceTime, allowFollowUpSchedule: shouldAllowFollowUpScheduling)
    }

    func handleDisplayTick(referenceTime: CFTimeInterval) {
        guard !renderingSuspended else { return }
        guard displayClockActive else { return }
        guard presentationTier == .activeLive else { return }
        guard streamID != nil else { return }

        _ = performPass(
            referenceTime: referenceTime,
            allowFollowUpSchedule: false,
            isDisplayTick: true
        )
    }

    private var shouldUseCoalescedFrameArrivalSubmission: Bool {
        false
    }

    private var shouldAllowFollowUpScheduling: Bool {
        false
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
        _ = performPass(referenceTime: referenceTime, allowFollowUpSchedule: shouldAllowFollowUpScheduling)
    }

    @discardableResult
    private func performPass(
        referenceTime: CFTimeInterval,
        allowFollowUpSchedule: Bool,
        isDisplayTick: Bool = false
    )
    -> MirageRenderSubmissionResult {
        guard let streamID else { return .blocked }

        if runningPass {
            pendingScheduledPass = true
            schedulePass(referenceTime: referenceTime)
            return .blocked
        }

        if isDisplayTick {
            MirageRenderStreamStore.shared.noteDisplayTick(for: streamID)
        }

        runningPass = true
        let submissionResult = submit(referenceTime)
        runningPass = false
        if submissionResult == .submitted {
            displayClockFramePending = false
        } else if isDisplayTick, submissionResult == .noPendingFrame, !displayClockFramePending {
            MirageRenderStreamStore.shared.noteRepeatedDisplayTick(for: streamID)
        }
        if submissionResult == .displayLayerNotReady {
            onDisplayLayerNotReady()
        }

        if pendingScheduledPass {
            pendingScheduledPass = false
            schedulePass(referenceTime: referenceTimeProvider())
            return submissionResult
        }

        guard allowFollowUpSchedule, submissionResult == .submitted, hasPendingFrame() else {
            return submissionResult
        }
        schedulePass(referenceTime: referenceTimeProvider())
        return submissionResult
    }
}
