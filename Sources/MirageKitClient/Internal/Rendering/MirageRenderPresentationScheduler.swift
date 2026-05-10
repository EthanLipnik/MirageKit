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

enum MirageRenderSubmissionSource: Equatable, Sendable {
    case immediate
    case readinessRetry
    case rendererReady
    case frameArrivalFallback
    case displayTick
    case scheduled
}

final class MirageRenderPresentationScheduler: @unchecked Sendable {
    private let referenceTimeProvider: () -> CFTimeInterval
    private let enqueueCoalescedPass: (@escaping @Sendable () -> Void) -> Void
    private let submit: (CFTimeInterval, MirageRenderSubmissionSource) -> MirageRenderSubmissionResult
    private let hasPendingFrame: () -> Bool
    private let pendingFrameCount: () -> Int
    private var onDisplayLayerNotReady: () -> Void

    private var streamID: StreamID?
    private var presentationTier: StreamPresentationTier = .activeLive
    private var renderingSuspended = false
    private var displayClockActive = false
    private var activeLiveFrameArrivalCatchUpPending = false
    private var lastDisplayTickWallTime: CFTimeInterval = 0

    private var scheduledPassPending = false
    private var scheduledPassGeneration: UInt64 = 0
    private var scheduledReferenceTime: CFTimeInterval?
    private var scheduledPassSource: MirageRenderSubmissionSource = .scheduled
    private var runningPass = false
    private var pendingScheduledPass = false
    private var scheduledPassIsFrameArrivalFallback = false
    private var targetFPS: Int = 60

    init(
        referenceTimeProvider: @escaping () -> CFTimeInterval = CACurrentMediaTime,
        enqueueCoalescedPass: @escaping (@escaping @Sendable () -> Void) -> Void = { action in
            Task {
                await Task.yield()
                action()
            }
        },
        submit: @escaping (CFTimeInterval) -> MirageRenderSubmissionResult,
        hasPendingFrame: @escaping () -> Bool = { false },
        pendingFrameCount: (() -> Int)? = nil,
        onDisplayLayerNotReady: @escaping () -> Void = {}
    ) {
        self.referenceTimeProvider = referenceTimeProvider
        self.enqueueCoalescedPass = enqueueCoalescedPass
        self.submit = { referenceTime, _ in submit(referenceTime) }
        self.hasPendingFrame = hasPendingFrame
        self.pendingFrameCount = pendingFrameCount ?? {
            hasPendingFrame() ? 1 : 0
        }
        self.onDisplayLayerNotReady = onDisplayLayerNotReady
    }

    init(
        referenceTimeProvider: @escaping () -> CFTimeInterval = CACurrentMediaTime,
        enqueueCoalescedPass: @escaping (@escaping @Sendable () -> Void) -> Void = { action in
            Task {
                await Task.yield()
                action()
            }
        },
        submitWithSource: @escaping (CFTimeInterval, MirageRenderSubmissionSource) -> MirageRenderSubmissionResult,
        hasPendingFrame: @escaping () -> Bool = { false },
        pendingFrameCount: (() -> Int)? = nil,
        onDisplayLayerNotReady: @escaping () -> Void = {}
    ) {
        self.referenceTimeProvider = referenceTimeProvider
        self.enqueueCoalescedPass = enqueueCoalescedPass
        submit = submitWithSource
        self.hasPendingFrame = hasPendingFrame
        self.pendingFrameCount = pendingFrameCount ?? {
            hasPendingFrame() ? 1 : 0
        }
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

    func setTargetFPS(_ fps: Int) {
        targetFPS = MirageRenderModePolicy.normalizedTargetFPS(fps)
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
        activeLiveFrameArrivalCatchUpPending = false
        lastDisplayTickWallTime = 0
        if active {
            scheduledPassPending = false
            scheduledPassGeneration &+= 1
            scheduledReferenceTime = nil
        }
    }

    func setDisplayLayerNotReadyHandler(_ handler: @escaping () -> Void) {
        onDisplayLayerNotReady = handler
    }

    func reset() {
        scheduledPassPending = false
        scheduledPassGeneration &+= 1
        scheduledReferenceTime = nil
        scheduledPassSource = .scheduled
        runningPass = false
        pendingScheduledPass = false
        scheduledPassIsFrameArrivalFallback = false
        activeLiveFrameArrivalCatchUpPending = false
        lastDisplayTickWallTime = 0
    }

    func requestImmediateSubmission(referenceTime: CFTimeInterval) {
        guard !renderingSuspended else { return }
        if presentationTier == .activeLive {
            guard hasPendingFrame() else { return }
            if !displayClockActive || lastDisplayTickWallTime == 0 {
                _ = performPass(
                    referenceTime: referenceTime,
                    allowFollowUpSchedule: false,
                    isDisplayTick: false,
                    source: .immediate
                )
            }
            return
        }
        _ = performPass(
            referenceTime: referenceTime,
            allowFollowUpSchedule: shouldAllowFollowUpScheduling,
            isDisplayTick: false,
            source: .immediate
        )
    }

    func requestReadinessRetry(referenceTime: CFTimeInterval) {
        guard !renderingSuspended else { return }
        if presentationTier == .activeLive {
            if !displayClockActive {
                schedulePass(referenceTime: referenceTime, source: .readinessRetry)
            }
            return
        }
        schedulePass(referenceTime: referenceTime, source: .readinessRetry)
    }

    func requestRendererReadySubmission(referenceTime: CFTimeInterval) {
        guard !renderingSuspended else { return }
        guard hasPendingFrame() else { return }
        if presentationTier == .activeLive, displayClockActive {
            guard shouldFailOpenActiveLiveSubmission() else { return }
        }
        _ = performPass(
            referenceTime: referenceTime,
            allowFollowUpSchedule: false,
            isDisplayTick: false,
            source: .rendererReady
        )
    }

    func handleFrameAvailable(referenceTime: CFTimeInterval) {
        guard !renderingSuspended else { return }

        if presentationTier == .activeLive {
            scheduleActiveLiveFallbackIfNeeded(referenceTime: referenceTime)
            return
        }

        if shouldUseCoalescedFrameArrivalSubmission {
            schedulePass(referenceTime: referenceTime, source: .scheduled)
            return
        }

        _ = performPass(referenceTime: referenceTime, allowFollowUpSchedule: shouldAllowFollowUpScheduling)
    }

    func handleDisplayTick(referenceTime: CFTimeInterval) {
        guard !renderingSuspended else { return }
        guard displayClockActive else { return }
        guard presentationTier == .activeLive else { return }
        guard streamID != nil else { return }

        lastDisplayTickWallTime = referenceTimeProvider()
        let result = performPass(
            referenceTime: referenceTime,
            allowFollowUpSchedule: false,
            isDisplayTick: true,
            source: .displayTick
        )
        switch result {
        case .noPendingFrame:
            activeLiveFrameArrivalCatchUpPending = true
        case .submitted, .displayLayerNotReady:
            activeLiveFrameArrivalCatchUpPending = false
        case .blocked:
            break
        }
    }

    private var shouldUseCoalescedFrameArrivalSubmission: Bool {
        false
    }

    private var shouldAllowFollowUpScheduling: Bool {
        false
    }

    private func scheduleActiveLiveFallbackIfNeeded(referenceTime: CFTimeInterval) {
        guard displayClockActive else {
            scheduleFrameArrivalFallback(referenceTime: referenceTime)
            return
        }
        guard lastDisplayTickWallTime != 0 else {
            scheduleFrameArrivalFallback(referenceTime: referenceTime)
            return
        }

        let availableFrameCount = pendingFrameCount()
        guard availableFrameCount > 0 else { return }
        let elapsedSinceDisplayTick = max(0, referenceTimeProvider() - lastDisplayTickWallTime)
        if activeLiveFrameArrivalCatchUpPending {
            noteFrameArrivedAfterNoFrameTick(delayMs: elapsedSinceDisplayTick * 1000)
        }
        let recoveryThreshold = activeLiveFallbackThreshold
        guard activeLiveFrameArrivalCatchUpPending ||
            availableFrameCount > 1 ||
            elapsedSinceDisplayTick >= recoveryThreshold
        else {
            return
        }
        guard elapsedSinceDisplayTick >= recoveryThreshold else { return }

        activeLiveFrameArrivalCatchUpPending = false
        scheduleFrameArrivalFallback(referenceTime: referenceTime)
    }

    private var activeLiveFallbackThreshold: CFTimeInterval {
        max(0.008, 0.85 / Double(max(1, targetFPS)))
    }

    private func shouldFailOpenActiveLiveSubmission() -> Bool {
        guard displayClockActive else { return true }
        guard lastDisplayTickWallTime != 0 else { return true }
        let elapsedSinceDisplayTick = max(0, referenceTimeProvider() - lastDisplayTickWallTime)
        return elapsedSinceDisplayTick >= activeLiveFallbackThreshold
    }

    @discardableResult
    private func schedulePass(
        referenceTime: CFTimeInterval,
        source: MirageRenderSubmissionSource = .scheduled
    ) -> Bool {
        if let scheduledReferenceTime {
            self.scheduledReferenceTime = max(scheduledReferenceTime, referenceTime)
        } else {
            scheduledReferenceTime = referenceTime
        }
        scheduledPassSource = source

        guard !scheduledPassPending else { return false }
        scheduledPassPending = true
        let generation = scheduledPassGeneration
        enqueueCoalescedPass { [weak self] in
            guard let self else { return }
            guard self.scheduledPassGeneration == generation else { return }
            self.scheduledPassPending = false
            self.runScheduledPass()
        }
        return true
    }

    private func scheduleFrameArrivalFallback(referenceTime: CFTimeInterval) {
        let wasFrameArrivalFallback = scheduledPassIsFrameArrivalFallback
        let previousSource = scheduledPassSource
        scheduledPassIsFrameArrivalFallback = true
        guard schedulePass(referenceTime: referenceTime, source: .frameArrivalFallback) else {
            scheduledPassIsFrameArrivalFallback = wasFrameArrivalFallback
            scheduledPassSource = previousSource
            return
        }
        noteFrameArrivalFallback()
    }

    private func runScheduledPass() {
        let referenceTime = scheduledReferenceTime ?? referenceTimeProvider()
        let isFrameArrivalFallback = scheduledPassIsFrameArrivalFallback
        let source = scheduledPassSource
        scheduledReferenceTime = nil
        scheduledPassIsFrameArrivalFallback = false
        scheduledPassSource = .scheduled
        let result = performPass(
            referenceTime: referenceTime,
            allowFollowUpSchedule: shouldAllowFollowUpScheduling,
            source: source
        )
        if isFrameArrivalFallback, result == .submitted {
            noteFrameArrivalFallbackSubmitted()
        }
    }

    @discardableResult
    private func performPass(
        referenceTime: CFTimeInterval,
        allowFollowUpSchedule: Bool,
        isDisplayTick: Bool = false,
        source: MirageRenderSubmissionSource = .scheduled
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
        let submissionResult = submit(referenceTime, source)
        runningPass = false
        if submissionResult == .submitted {
            activeLiveFrameArrivalCatchUpPending = false
            if source != .scheduled, source != .frameArrivalFallback {
                cancelScheduledPasses()
            }
        }
        if isDisplayTick, submissionResult == .noPendingFrame {
            MirageRenderStreamStore.shared.noteDisplayTickWithoutFrame(for: streamID)
            MirageRenderStreamStore.shared.noteRepeatedDisplayTick(for: streamID)
        }
        if submissionResult == .displayLayerNotReady, shouldArmDisplayLayerReadinessRetry {
            onDisplayLayerNotReady()
        }

        if pendingScheduledPass {
            pendingScheduledPass = false
            schedulePass(referenceTime: referenceTimeProvider(), source: .scheduled)
            return submissionResult
        }

        guard allowFollowUpSchedule, submissionResult == .submitted, hasPendingFrame() else {
            return submissionResult
        }
        schedulePass(referenceTime: referenceTimeProvider(), source: .scheduled)
        return submissionResult
    }

    private func cancelScheduledPasses() {
        scheduledPassPending = false
        scheduledPassGeneration &+= 1
        scheduledReferenceTime = nil
        scheduledPassSource = .scheduled
        scheduledPassIsFrameArrivalFallback = false
        pendingScheduledPass = false
    }

    private var shouldArmDisplayLayerReadinessRetry: Bool {
        !(presentationTier == .activeLive && displayClockActive)
    }

    private func noteFrameArrivalFallback() {
        guard let streamID else { return }
        MirageRenderStreamStore.shared.noteFrameArrivalFallback(for: streamID)
    }

    private func noteFrameArrivalFallbackSubmitted() {
        guard let streamID else { return }
        MirageRenderStreamStore.shared.noteFrameArrivalFallbackSubmitted(for: streamID)
    }

    private func noteFrameArrivedAfterNoFrameTick(delayMs: Double) {
        guard let streamID else { return }
        MirageRenderStreamStore.shared.noteFrameArrivedAfterNoFrameTick(for: streamID, delayMs: delayMs)
    }
}
