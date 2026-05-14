//
//  MirageRenderPresentationScheduler.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/12/26.
//

import Foundation
import MirageKit
import QuartzCore

enum MirageRenderSubmissionResult: Equatable {
    case submitted
    case noPendingFrame
    case displayLayerNotReady
    case blocked
}

final class MirageRenderPresentationScheduler: @unchecked Sendable {
    private let referenceTimeProvider: () -> CFTimeInterval
    private let enqueueCoalescedPass: (@escaping @Sendable () -> Void) -> Void
    private let submit: (CFTimeInterval) -> MirageRenderSubmissionResult
    private let hasPendingFrame: () -> Bool
    private let pendingFrameCount: () -> Int
    private var onDisplayLayerNotReady: () -> Void

    private var streamID: StreamID?
    private var presentationTier: StreamPresentationTier = .activeLive
    private var renderingSuspended = false
    private var displayClockActive = false
    private var displayClockFramePending = false
    private var lastDisplayTickWallTime: CFTimeInterval = 0

    private var scheduledPassPending = false
    private var scheduledPassGeneration: UInt64 = 0
    private var scheduledReferenceTime: CFTimeInterval?
    private var scheduledPassIsFrameArrivalFallback = false
    private var runningPass = false
    private var pendingScheduledPass = false
    private var targetFPS: Int = 60

    private var activeLiveFallbackThreshold: CFTimeInterval {
        let targetFrameInterval = 1.0 / Double(max(1, targetFPS))
        return min(0.050, max(1.0 / 120.0, targetFrameInterval * 1.25))
    }

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
        self.submit = submit
        self.hasPendingFrame = hasPendingFrame
        self.pendingFrameCount = pendingFrameCount ?? { hasPendingFrame() ? 1 : 0 }
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
        displayClockFramePending = false
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
        scheduledPassIsFrameArrivalFallback = false
        runningPass = false
        pendingScheduledPass = false
        displayClockFramePending = false
        lastDisplayTickWallTime = 0
    }

    func requestImmediateSubmission(referenceTime: CFTimeInterval) {
        guard !renderingSuspended else { return }
        if presentationTier == .activeLive {
            guard hasPendingFrame() else { return }
            displayClockFramePending = true
            if !displayClockActive || lastDisplayTickWallTime == 0 {
                performPass(
                    referenceTime: referenceTime,
                    isDisplayTick: false
                )
            }
            return
        }
        performPass(
            referenceTime: referenceTime,
            isDisplayTick: false
        )
    }

    func requestReadinessRetry(referenceTime: CFTimeInterval) {
        guard !renderingSuspended else { return }
        if presentationTier == .activeLive {
            if !displayClockActive {
                schedulePass(referenceTime: referenceTime)
                return
            }
            displayClockFramePending = true
            return
        }
        schedulePass(referenceTime: referenceTime)
    }

    func requestRendererReadySubmission(referenceTime: CFTimeInterval) {
        guard !renderingSuspended else { return }
        guard hasPendingFrame() else { return }
        if presentationTier == .activeLive, displayClockActive {
            guard lastDisplayTickWallTime == 0 ||
                referenceTimeProvider() - lastDisplayTickWallTime >= activeLiveFallbackThreshold else {
                return
            }
        }
        performPass(
            referenceTime: referenceTime,
            isDisplayTick: false
        )
    }

    func handleFrameAvailable(referenceTime: CFTimeInterval) {
        guard !renderingSuspended else { return }

        if presentationTier == .activeLive {
            let arrivedAfterNoFrameTick = displayClockFramePending
            displayClockFramePending = true
            if arrivedAfterNoFrameTick {
                noteFrameArrivedAfterNoFrameTick(delayMs: max(0, referenceTimeProvider() - lastDisplayTickWallTime) * 1000)
            }
            scheduleActiveLiveFallbackIfNeeded(referenceTime: referenceTime)
            return
        }

        performPass(referenceTime: referenceTime)
    }

    func handleDisplayTick(referenceTime: CFTimeInterval) {
        guard !renderingSuspended else { return }
        guard displayClockActive else { return }
        guard presentationTier == .activeLive else { return }
        guard streamID != nil else { return }

        lastDisplayTickWallTime = referenceTimeProvider()
        performPass(
            referenceTime: referenceTime,
            isDisplayTick: true
        )
    }

    private func scheduleActiveLiveFallbackIfNeeded(referenceTime: CFTimeInterval) {
        guard displayClockActive else {
            schedulePass(referenceTime: referenceTime)
            return
        }
        let now = referenceTimeProvider()
        guard pendingFrameCount() > 0 else { return }
        guard lastDisplayTickWallTime == 0 ||
            now - lastDisplayTickWallTime >= activeLiveFallbackThreshold else {
            return
        }
        noteFrameArrivalFallback()
        schedulePass(referenceTime: referenceTime, isFrameArrivalFallback: true)
    }

    private func schedulePass(referenceTime: CFTimeInterval, isFrameArrivalFallback: Bool = false) {
        if let scheduledReferenceTime {
            self.scheduledReferenceTime = max(scheduledReferenceTime, referenceTime)
        } else {
            scheduledReferenceTime = referenceTime
        }
        scheduledPassIsFrameArrivalFallback = scheduledPassIsFrameArrivalFallback || isFrameArrivalFallback

        guard !scheduledPassPending else { return }
        scheduledPassPending = true
        let generation = scheduledPassGeneration
        enqueueCoalescedPass { [weak self] in
            guard let self else { return }
            guard scheduledPassGeneration == generation else { return }
            scheduledPassPending = false
            let referenceTime = scheduledReferenceTime ?? referenceTimeProvider()
            let isFrameArrivalFallback = scheduledPassIsFrameArrivalFallback
            scheduledReferenceTime = nil
            scheduledPassIsFrameArrivalFallback = false
            let result = performPass(referenceTime: referenceTime)
            if isFrameArrivalFallback, result == .submitted {
                noteFrameArrivalFallbackSubmitted()
            }
        }
    }

    @discardableResult
    private func performPass(
        referenceTime: CFTimeInterval,
        isDisplayTick: Bool = false
    ) -> MirageRenderSubmissionResult {
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
        } else if isDisplayTick, submissionResult == .noPendingFrame {
            MirageRenderStreamStore.shared.noteDisplayTickWithoutFrame(for: streamID)
            MirageRenderStreamStore.shared.noteRepeatedDisplayTick(for: streamID)
            displayClockFramePending = true
        }
        if submissionResult == .displayLayerNotReady {
            onDisplayLayerNotReady()
        }

        if pendingScheduledPass {
            pendingScheduledPass = false
            schedulePass(referenceTime: referenceTimeProvider())
        }
        return submissionResult
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
