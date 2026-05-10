//
//  MirageSampleBufferPresentationWorker.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/9/26.
//
//  Off-main display-tick driven sample-buffer presentation worker.
//

import AVFoundation
import Foundation
import MirageKit
import QuartzCore

final class MirageSampleBufferPresentationWorker: @unchecked Sendable {
    private struct PendingDisplayTick {
        var referenceTime: CFTimeInterval
        var enqueueTime: CFTimeInterval
        var callbackCount: UInt64
    }

    private let worker: MirageRenderSerialWorker
    private let pendingTickLock = NSLock()
    private let presenter: MirageSampleBufferPresenter
    private let scheduler: MirageRenderPresentationScheduler
    private var streamID: StreamID?
    private var displayLayerReadinessRetryTask: Task<Void, Never>?
    private var pendingDisplayTick: PendingDisplayTick?
    private var displayTickDeliveryPending = false

    init(displayLayer: AVSampleBufferDisplayLayer, platformName: String) {
        let worker = MirageRenderSerialWorker(
            label: "com.ethanlipnik.mirage.client.presentation.\(platformName.lowercased())"
        )
        let presenter = MirageSampleBufferPresenter(
            displayLayer: displayLayer,
            rendererReadinessQueue: worker.dispatchQueue
        )
        self.worker = worker
        self.presenter = presenter
        scheduler = MirageRenderPresentationScheduler(
            enqueueCoalescedPass: { [weak worker] action in
                worker?.submit(action)
            },
            submitWithSource: { [weak presenter] referenceTime, source in
                presenter?.submitPendingFrameIfPossible(
                    referenceTime: referenceTime,
                    source: source
                ) ?? .blocked
            },
            hasPendingFrame: { [weak presenter] in
                presenter?.hasPendingFrameForCurrentPresenter ?? false
            },
            pendingFrameCount: { [weak presenter] in
                presenter?.pendingFrameCountForCurrentPresenter ?? 0
            }
        )
        scheduler.setPresentationTier(.activeLive)
        scheduler.setDisplayLayerNotReadyHandler { [weak self] in
            self?.worker.submit { [weak self] in
                self?.armDisplayLayerReadinessRetryLocked()
            }
        }
        presenter.onFrameAvailable = { [weak self] in
            self?.handleFrameAvailable(referenceTime: CACurrentMediaTime())
        }
        presenter.onPresentationRecoveryRequested = { [weak self] in
            self?.recoverPresentationPipeline()
        }
        presenter.onRendererReadyForMoreMediaData = { [weak self] in
            self?.handleRendererReadyForMoreMediaData()
        }
    }

    deinit {
        displayLayerReadinessRetryTask?.cancel()
    }

    func setStreamID(_ newStreamID: StreamID?) {
        worker.sync {
            if streamID != newStreamID {
                cancelDisplayLayerReadinessRetryLocked()
                clearPendingDisplayTick()
            }
            streamID = newStreamID
            presenter.setStreamID(newStreamID)
            scheduler.setStreamID(newStreamID)
        }
    }

    func setPresentationTier(_ tier: StreamPresentationTier) {
        worker.sync {
            scheduler.setPresentationTier(tier)
        }
    }

    func setTargetFPS(_ fps: Int) {
        worker.sync {
            presenter.setTargetFPS(fps)
            scheduler.setTargetFPS(fps)
        }
    }

    func setCadenceTarget(_ target: MirageStreamCadenceTarget) {
        worker.sync {
            presenter.setCadenceTarget(target)
            scheduler.setTargetFPS(target.displayFPS)
        }
    }

    func setContentRectOverride(_ contentRect: CGRect?) {
        worker.sync {
            presenter.setContentRectOverride(contentRect)
        }
    }

    func setRenderingSuspended(_ suspended: Bool, clearCurrentFrame: Bool) {
        worker.sync {
            if suspended {
                cancelDisplayLayerReadinessRetryLocked()
                clearPendingDisplayTick()
            }
            presenter.setRenderingSuspended(suspended, clearCurrentFrame: clearCurrentFrame)
            scheduler.setRenderingSuspended(suspended)
        }
    }

    func resetPresentationState(preserveLoggedLayerFailure: Bool = false) {
        worker.sync {
            presenter.resetPresentationState(preserveLoggedLayerFailure: preserveLoggedLayerFailure)
        }
    }

    func resetScheduler() {
        worker.sync {
            scheduler.reset()
        }
    }

    func setDisplayClockActive(_ active: Bool) {
        worker.sync {
            scheduler.setDisplayClockActive(active)
            if !active {
                clearPendingDisplayTick()
            }
        }
    }

    func requestImmediateSubmission(referenceTime: CFTimeInterval) {
        worker.submit { [weak self] in
            self?.scheduler.requestImmediateSubmission(referenceTime: referenceTime)
        }
    }

    func requestReadinessRetry(referenceTime: CFTimeInterval) {
        worker.submit { [weak self] in
            self?.scheduler.requestReadinessRetry(referenceTime: referenceTime)
        }
    }

    func handleFrameAvailable(referenceTime: CFTimeInterval) {
        worker.submit { [weak self] in
            self?.scheduler.handleFrameAvailable(referenceTime: referenceTime)
        }
    }

    func handleDisplayLinkTick(referenceTime: CFTimeInterval) {
        let enqueueTime = CACurrentMediaTime()
        let shouldSchedule: Bool
        pendingTickLock.lock()
        if var pendingDisplayTick {
            pendingDisplayTick.referenceTime = referenceTime
            pendingDisplayTick.enqueueTime = enqueueTime
            pendingDisplayTick.callbackCount &+= 1
            self.pendingDisplayTick = pendingDisplayTick
            shouldSchedule = false
        } else {
            pendingDisplayTick = PendingDisplayTick(
                referenceTime: referenceTime,
                enqueueTime: enqueueTime,
                callbackCount: 1
            )
            shouldSchedule = !displayTickDeliveryPending
        }
        if shouldSchedule {
            displayTickDeliveryPending = true
        }
        pendingTickLock.unlock()

        guard shouldSchedule else { return }
        worker.submit { [weak self] in
            self?.deliverLatestDisplayTick()
        }
    }

    var hasDisplayLayerFailure: Bool {
        worker.sync {
            presenter.hasDisplayLayerFailure
        }
    }

    var currentContentReferenceSize: CGSize? {
        worker.sync {
            presenter.currentContentReferenceSize
        }
    }

    private func deliverLatestDisplayTick() {
        let tick: PendingDisplayTick?
        pendingTickLock.lock()
        tick = pendingDisplayTick
        pendingDisplayTick = nil
        displayTickDeliveryPending = false
        pendingTickLock.unlock()

        guard let tick else { return }
        if let streamID {
            MirageRenderStreamStore.shared.noteDisplayLinkCallbacks(
                for: streamID,
                count: tick.callbackCount
            )
            MirageRenderStreamStore.shared.noteDisplayTickWorker(for: streamID)
            MirageRenderStreamStore.shared.noteRenderWorkerSubmitDelay(
                for: streamID,
                delayMs: max(0, CACurrentMediaTime() - tick.enqueueTime) * 1000
            )
        }
        scheduler.handleDisplayTick(referenceTime: tick.referenceTime)
    }

    private func recoverPresentationPipeline() {
        worker.submit { [weak self] in
            guard let self else { return }
            presenter.setStreamID(streamID)
            scheduler.setStreamID(streamID)
            presenter.resetPresentationState(preserveLoggedLayerFailure: true)
            scheduler.reset()
            presenter.setRenderingSuspended(false, clearCurrentFrame: false)
            scheduler.setRenderingSuspended(false)
            scheduler.requestImmediateSubmission(referenceTime: CACurrentMediaTime())
        }
    }

    private func handleRendererReadyForMoreMediaData() {
        guard presenter.hasPendingFrameForCurrentPresenter else { return }
        scheduler.requestRendererReadySubmission(referenceTime: CACurrentMediaTime())
    }

    private func armDisplayLayerReadinessRetryLocked() {
        guard displayLayerReadinessRetryTask == nil else { return }
        displayLayerReadinessRetryTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(16))
            guard !Task.isCancelled else { return }
            self?.worker.submit { [weak self] in
                guard let self else { return }
                displayLayerReadinessRetryTask = nil
                scheduler.requestReadinessRetry(referenceTime: CACurrentMediaTime())
            }
        }
    }

    private func cancelDisplayLayerReadinessRetryLocked() {
        displayLayerReadinessRetryTask?.cancel()
        displayLayerReadinessRetryTask = nil
    }

    private func clearPendingDisplayTick() {
        pendingTickLock.lock()
        pendingDisplayTick = nil
        displayTickDeliveryPending = false
        pendingTickLock.unlock()
    }
}
