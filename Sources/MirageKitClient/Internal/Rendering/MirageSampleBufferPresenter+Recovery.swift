//
//  MirageSampleBufferPresenter+Recovery.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/13/26.
//

import AVFoundation
import Foundation
import MirageKit

extension MirageSampleBufferPresenter {
    /// Registers render-store callbacks that wake the presenter when frames or recovery signals arrive.
    func registerFrameListener(for streamID: StreamID?) {
        guard let streamID else { return }
        listenerStreamID = streamID
        MirageRenderStreamStore.shared.registerFrameListener(for: streamID, owner: self) { [weak self] in
            guard let self else { return }
            if Thread.isMainThread {
                self.onFrameAvailable?()
            } else {
                Task { @MainActor [weak self] in
                    self?.onFrameAvailable?()
                }
            }
        }
        if onPresentationRecoveryRequested != nil {
            MirageRenderStreamStore.shared.registerPresentationRecoveryHandler(for: streamID, owner: self) { [weak self] in
                guard let self else { return }
                if Thread.isMainThread {
                    self.onPresentationRecoveryRequested?()
                } else {
                    Task { @MainActor [weak self] in
                        self?.onPresentationRecoveryRequested?()
                    }
                }
            }
        }
    }

    /// Unregisters render-store callbacks owned by this presenter.
    func unregisterFrameListener(for streamID: StreamID?) {
        guard let streamID else { return }
        MirageRenderStreamStore.shared.unregisterFrameListener(for: streamID, owner: self)
        MirageRenderStreamStore.shared.unregisterPresentationRecoveryHandler(for: streamID, owner: self)
        if listenerStreamID == streamID {
            listenerStreamID = nil
        }
    }

    /// Rebuilds render-store callbacks after sequence tracking is reset.
    func refreshFrameListener(for streamID: StreamID) {
        unregisterFrameListener(for: listenerStreamID)
        registerFrameListener(for: streamID)
    }

    /// Logs playout withholding separately from display-layer backpressure.
    func logPendingFrameNotReadyIfNeeded(streamID: StreamID, now: CFTimeInterval) {
        guard now - lastPendingFrameNotReadyLogTime >= 0.5 else { return }
        lastPendingFrameNotReadyLogTime = now
        let pendingCount = MirageRenderStreamStore.shared.pendingFrameCount(for: streamID)
        let pendingAgeMs = MirageRenderStreamStore.shared.pendingFrameAgeMs(for: streamID)
        MirageLogger.renderer(
            "Presentation pending frame not ready: stream=\(streamID) pending=\(pendingCount) ageMs=\(Int(pendingAgeMs.rounded()))"
        )
    }

    /// Resets presentation if the display layer stays back-pressured while frames are available.
    func recoverDisplayLayerLivenessIfNeeded(
        now: CFTimeInterval,
        presenterHasPendingFrame: Bool
    ) {
        guard presenterHasPendingFrame else {
            displayLayerNotReadyStartTime = 0
            return
        }

        if displayLayerNotReadyStartTime == 0 {
            displayLayerNotReadyStartTime = now
            return
        }

        let lastProgressTime = max(displayLayerNotReadyStartTime, lastFrameSubmissionTime)
        guard now - lastProgressTime >= Self.displayLayerLivenessResetThresholdSeconds else { return }

        MirageLogger.renderer(
            "Display layer remained not-ready with a presenter-pending frame; resetting presentation pipeline"
        )
        resetPresentationState(removeDisplayedImage: false)
    }

    /// Flushes and resets failed display layers, suppressing expected teardown interruptions.
    func recoverDisplayLayerIfNeeded() {
        guard let displayLayer, displayLayer.status == .failed else { return }
        if !loggedLayerFailure {
            if Self.isExpectedDisplayLayerFailure(displayLayer.error) {
                let description = displayLayer.error?.localizedDescription ?? "unknown error"
                MirageLogger.renderer("AVSampleBufferDisplayLayer interruption during teardown: \(description)")
            } else {
                let description = displayLayer.error?.localizedDescription ?? "unknown error"
                MirageLogger.error(.renderer, "AVSampleBufferDisplayLayer failure: \(description)")
            }
            loggedLayerFailure = true
        }
        resetPresentationState(preserveLoggedLayerFailure: true, removeDisplayedImage: false)
    }

    /// Returns whether an AVSampleBufferDisplayLayer failure is expected during teardown.
    nonisolated static func isExpectedDisplayLayerFailure(_ error: Error?) -> Bool {
        guard let nsError = error as NSError? else { return false }
        guard nsError.domain == AVFoundationErrorDomain else { return false }
        return expectedDisplayLayerAVErrorCodes.contains(nsError.code)
    }

    nonisolated static let expectedDisplayLayerAVErrorCodes: Set<Int> = [
        -11847, // AVErrorOperationInterrupted
        -11818, // AVErrorSessionWasInterrupted
    ]
}
