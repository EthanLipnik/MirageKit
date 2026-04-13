//
//  MirageRenderPresentationScheduler.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/12/26.
//

import Foundation
import MirageKit
import QuartzCore

@MainActor
final class MirageRenderPresentationScheduler {
    private let referenceTimeProvider: () -> CFTimeInterval
    private let enqueueCoalescedPass: (@escaping @MainActor () -> Void) -> Void
    private let submit: @MainActor (CFTimeInterval) -> Bool
    private let hasPendingFrame: (StreamID) -> Bool

    private var streamID: StreamID?
    private var presentationTier: StreamPresentationTier = .activeLive
    private var displayLinkActive = false
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
        submit: @escaping @MainActor (CFTimeInterval) -> Bool,
        hasPendingFrame: @escaping (StreamID) -> Bool = {
            MirageRenderStreamStore.shared.pendingFrameCount(for: $0) > 0
        }
    ) {
        self.referenceTimeProvider = referenceTimeProvider
        self.enqueueCoalescedPass = enqueueCoalescedPass
        self.submit = submit
        self.hasPendingFrame = hasPendingFrame
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

    func setDisplayLinkActive(_ active: Bool) {
        displayLinkActive = active
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

    func handleFrameAvailable(referenceTime: CFTimeInterval) {
        guard !renderingSuspended else { return }

        if shouldUseCoalescedFrameArrivalSubmission {
            schedulePass(referenceTime: referenceTime)
            return
        }

        performPass(referenceTime: referenceTime, allowFollowUpSchedule: shouldAllowFollowUpScheduling)
    }

    func displayLinkTick(referenceTime: CFTimeInterval) {
        guard !renderingSuspended else { return }
        guard !scheduledPassPending else { return }
        performPass(referenceTime: referenceTime, allowFollowUpSchedule: shouldAllowFollowUpScheduling)
    }

    private var shouldUseCoalescedFrameArrivalSubmission: Bool {
        presentationTier == .activeLive && displayLinkActive
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
        guard let streamID else { return }

        if runningPass {
            pendingScheduledPass = true
            schedulePass(referenceTime: referenceTime)
            return
        }

        runningPass = true
        let didSubmit = submit(referenceTime)
        runningPass = false

        if pendingScheduledPass {
            pendingScheduledPass = false
            schedulePass(referenceTime: referenceTimeProvider())
            return
        }

        guard allowFollowUpSchedule, didSubmit, hasPendingFrame(streamID) else { return }
        schedulePass(referenceTime: referenceTimeProvider())
    }
}
