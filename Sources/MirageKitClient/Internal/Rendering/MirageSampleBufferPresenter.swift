//
//  MirageSampleBufferPresenter.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/2/26.
//
//  Shared AVSampleBufferDisplayLayer presentation path for client platforms.
//

import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import MirageKit

final class MirageSampleBufferPresenter: @unchecked Sendable {
    private struct PixelBufferFormatKey: Equatable {
        let width: Int
        let height: Int
        let pixelFormat: OSType
        let colorPrimaries: String?
        let transferFunction: String?
        let yCbCrMatrix: String?
    }

    static let cmTimeScale: CMTimeScale = 1_000_000_000
    static let presentationRebaseThresholdSeconds: CFTimeInterval = 1.0
    static let stallRecoveryThresholdSeconds: CFTimeInterval = 0.5
    static let displayLayerLivenessResetThresholdSeconds: CFTimeInterval = 0.75

    private weak var displayLayer: AVSampleBufferDisplayLayer?
    private let pixelBufferCropper = MiragePixelBufferCropper()

    private var streamID: StreamID?
    private var listenerStreamID: StreamID?
    private var maxRenderFPS: Int = 60
    private var renderingSuspended = false
    private var contentRectOverride: CGRect?

    private var cachedFormatKey: PixelBufferFormatKey?
    private var cachedFormatDescription: CMVideoFormatDescription?
    private var lastSubmittedSequence: UInt64 = 0
    private var remotePresentationOrigin: CMTime?
    private var localPresentationOrigin: CFTimeInterval?
    private var lastMappedPresentationTime: CMTime = .invalid
    private var loggedLayerFailure = false
    private var lastFrameSubmissionTime: CFTimeInterval = 0
    private var displayLayerNotReadyStartTime: CFTimeInterval = 0
    private(set) var currentContentReferenceSize: CGSize?

    var onFrameAvailable: (() -> Void)?
    var onPresentationRecoveryRequested: (() -> Void)?

    init(displayLayer: AVSampleBufferDisplayLayer) {
        self.displayLayer = displayLayer
    }

    deinit {
        unregisterFrameListener(for: listenerStreamID)
    }

    var hasDisplayLayerFailure: Bool {
        displayLayer?.status == .failed
    }

    var hasPendingFrameForCurrentPresenter: Bool {
        guard let streamID else { return false }
        guard let frame = MirageRenderStreamStore.shared.peekPendingFrame(for: streamID) else { return false }
        return frame.sequence > lastSubmittedSequence
    }

    func setTargetFPS(_ fps: Int) {
        let normalized = MirageRenderModePolicy.normalizedTargetFPS(fps)
        maxRenderFPS = normalized
        if let streamID {
            MirageRenderStreamStore.shared.setTargetFPS(for: streamID, targetFPS: normalized)
        }
    }

    func setStreamID(_ newStreamID: StreamID?) {
        if newStreamID == streamID {
            registerFrameListener(for: newStreamID)
            if let newStreamID {
                MirageRenderStreamStore.shared.setTargetFPS(for: newStreamID, targetFPS: maxRenderFPS)
            }
            return
        }
        unregisterFrameListener(for: streamID)
        streamID = newStreamID
        registerFrameListener(for: newStreamID)
        if let newStreamID {
            MirageRenderStreamStore.shared.setTargetFPS(for: newStreamID, targetFPS: maxRenderFPS)
        }
        resetPresentationState()
    }

    func setContentRectOverride(_ contentRect: CGRect?) {
        guard contentRectOverride != contentRect else { return }
        contentRectOverride = contentRect
        cachedFormatKey = nil
        cachedFormatDescription = nil
        currentContentReferenceSize = nil
    }

    func setRenderingSuspended(_ suspended: Bool, clearCurrentFrame: Bool) {
        renderingSuspended = suspended
        guard suspended else { return }
        guard clearCurrentFrame else { return }
        clearCurrentFrameState()
    }

    func resetPresentationState(preserveLoggedLayerFailure: Bool = false) {
        cachedFormatKey = nil
        cachedFormatDescription = nil
        resetSequenceTrackingState()
        if !preserveLoggedLayerFailure {
            loggedLayerFailure = false
        }
        clearCurrentFrameState()
    }

    private func clearCurrentFrameState() {
        guard let displayLayer else { return }
        displayLayer.flushAndRemoveImage()
        displayLayer.contentsRect = CGRect(x: 0, y: 0, width: 1, height: 1)
        currentContentReferenceSize = nil
        lastSubmittedSequence = 0
        displayLayerNotReadyStartTime = 0
    }

    @discardableResult
    func submitPendingFrameIfPossible(referenceTime: CFTimeInterval) -> MirageRenderSubmissionResult {
        guard let streamID, let displayLayer else { return .blocked }
        guard !renderingSuspended else { return .blocked }
        recoverDisplayLayerIfNeeded()
        guard displayLayer.status != .failed else { return .blocked }

        let now = CACurrentMediaTime()
        guard let frame = MirageRenderStreamStore.shared.peekPendingFrame(for: streamID) else {
            return .noPendingFrame
        }

        if frame.sequence <= lastSubmittedSequence {
            let latestSequence = MirageRenderStreamStore.shared.latestSequence(for: streamID)
            if latestSequence > 0, latestSequence < lastSubmittedSequence {
                MirageLogger
                    .renderer(
                        "Detected render sequence regression for stream \(streamID) (\(lastSubmittedSequence) -> \(latestSequence)); rebasing presenter state"
            )
                resetSequenceTrackingState()
                refreshFrameListener(for: streamID)
            }
            guard frame.sequence > lastSubmittedSequence else { return .noPendingFrame }
        }

        MirageRenderStreamStore.shared.noteSubmitAttempt(for: streamID)
        guard displayLayer.isReadyForMoreMediaData else {
            MirageRenderStreamStore.shared.noteDisplayLayerNotReady(for: streamID)
            recoverDisplayLayerLivenessIfNeeded(now: now, presenterHasPendingFrame: true)
            return .displayLayerNotReady
        }
        displayLayerNotReadyStartTime = 0

        // Detect presentation stalls (backpressure, display sleep, window occlusion)
        // only when a new frame is actually waiting, then rebase time mapping to
        // prevent fast-forward playback on recovery.
        if lastFrameSubmissionTime > 0, (now - lastFrameSubmissionTime) > Self.stallRecoveryThresholdSeconds {
            MirageLogger.renderer(
                "Presentation stall detected (\(String(format: "%.2f", now - lastFrameSubmissionTime))s gap); rebasing time origin"
            )
            resetSequenceTrackingState()
        }

        let pixelBuffer = presentationPixelBuffer(for: frame)
        guard let (sampleBuffer, mappedPresentationTime) = makeSampleBuffer(
            from: pixelBuffer,
            presentationTime: frame.presentationTime,
            referenceTime: referenceTime
        ) else {
            return .blocked
        }

        displayLayer.enqueue(sampleBuffer)
        lastSubmittedSequence = frame.sequence
        lastFrameSubmissionTime = CACurrentMediaTime()
        displayLayerNotReadyStartTime = 0
        MirageRenderStreamStore.shared.markSubmitted(
            sequence: frame.sequence,
            remotePresentationTime: frame.presentationTime,
            mappedPresentationTime: mappedPresentationTime,
            for: streamID
        )
        return .submitted
    }

    private func presentationPixelBuffer(for frame: MirageRenderFrame) -> CVPixelBuffer {
        guard let contentRectOverride else {
            updateLayerContentRect(frame.contentRect, pixelBuffer: frame.pixelBuffer)
            return frame.pixelBuffer
        }

        guard let cropResult = pixelBufferCropper.crop(frame.pixelBuffer, to: contentRectOverride) else {
            updateLayerContentRect(contentRectOverride, pixelBuffer: frame.pixelBuffer)
            return frame.pixelBuffer
        }

        resetLayerContentRect(to: cropResult.contentRect)
        return cropResult.pixelBuffer
    }

    private func resetSequenceTrackingState() {
        lastSubmittedSequence = 0
        remotePresentationOrigin = nil
        localPresentationOrigin = nil
        lastMappedPresentationTime = .invalid
        lastFrameSubmissionTime = 0
        displayLayerNotReadyStartTime = 0
    }

    private func updateLayerContentRect(_ contentRect: CGRect, pixelBuffer: CVPixelBuffer) {
        guard let displayLayer else { return }
        let width = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let height = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        guard width > 0, height > 0 else {
            displayLayer.contentsRect = CGRect(x: 0, y: 0, width: 1, height: 1)
            currentContentReferenceSize = nil
            return
        }

        let resolvedContentRect: CGRect
        if contentRect.width > 0, contentRect.height > 0 {
            resolvedContentRect = contentRect
        } else {
            resolvedContentRect = CGRect(x: 0, y: 0, width: width, height: height)
        }
        currentContentReferenceSize = resolvedContentRect.size

        let normalized = CGRect(
            x: min(max(resolvedContentRect.origin.x / width, 0), 1),
            y: min(max(resolvedContentRect.origin.y / height, 0), 1),
            width: min(max(resolvedContentRect.size.width / width, 0), 1),
            height: min(max(resolvedContentRect.size.height / height, 0), 1)
        )
        displayLayer.contentsRect = normalized
    }

    private func resetLayerContentRect(to contentRect: CGRect) {
        guard let displayLayer else { return }
        displayLayer.contentsRect = CGRect(x: 0, y: 0, width: 1, height: 1)
        currentContentReferenceSize = contentRect.size
    }

    private func makeSampleBuffer(
        from pixelBuffer: CVPixelBuffer,
        presentationTime: CMTime,
        referenceTime: CFTimeInterval
    ) -> (sampleBuffer: CMSampleBuffer, mappedPresentationTime: CMTime)? {
        guard let formatDescription = formatDescription(for: pixelBuffer) else { return nil }

        let samplePresentationTime = mappedPresentationTime(
            remotePresentationTime: presentationTime,
            referenceTime: referenceTime
        )

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: samplePresentationTime,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )

        guard status == noErr, let sampleBuffer else {
            MirageLogger.error(.renderer, "CMSampleBufferCreateReadyWithImageBuffer failed: \(status)")
            return nil
        }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
           let first = (attachments as NSArray).firstObject as? NSMutableDictionary {
            first[kCMSampleAttachmentKey_DisplayImmediately] = kCFBooleanTrue
        }
        return (sampleBuffer, samplePresentationTime)
    }

    private func mappedPresentationTime(
        remotePresentationTime: CMTime,
        referenceTime: CFTimeInterval
    ) -> CMTime {
        let fallbackNow = CMTime(seconds: referenceTime, preferredTimescale: Self.cmTimeScale)
        guard remotePresentationTime.isValid else {
            return makeMonotonicPresentationTime(from: fallbackNow)
        }

        if remotePresentationOrigin == nil || localPresentationOrigin == nil {
            remotePresentationOrigin = remotePresentationTime
            localPresentationOrigin = referenceTime
            return makeMonotonicPresentationTime(from: fallbackNow)
        }

        guard let remoteOrigin = remotePresentationOrigin,
              let localOrigin = localPresentationOrigin else {
            return makeMonotonicPresentationTime(from: fallbackNow)
        }

        let delta = CMTimeSubtract(remotePresentationTime, remoteOrigin)
        let deltaSeconds = CMTimeGetSeconds(delta)
        guard deltaSeconds.isFinite else {
            return makeMonotonicPresentationTime(from: fallbackNow)
        }

        if deltaSeconds < -Self.presentationRebaseThresholdSeconds ||
            deltaSeconds > 60 * 60 {
            remotePresentationOrigin = remotePresentationTime
            localPresentationOrigin = referenceTime
            return makeMonotonicPresentationTime(from: fallbackNow)
        }

        let localSeconds = localOrigin + max(0, deltaSeconds)
        let mapped = CMTime(seconds: localSeconds, preferredTimescale: Self.cmTimeScale)
        return makeMonotonicPresentationTime(from: mapped)
    }

    private func makeMonotonicPresentationTime(from candidate: CMTime) -> CMTime {
        guard lastMappedPresentationTime.isValid else {
            lastMappedPresentationTime = candidate
            return candidate
        }

        if CMTimeCompare(candidate, lastMappedPresentationTime) > 0 {
            lastMappedPresentationTime = candidate
            return candidate
        }

        let minStepTimescale = max(60, maxRenderFPS)
        let stepped = CMTimeAdd(
            lastMappedPresentationTime,
            CMTime(value: 1, timescale: CMTimeScale(minStepTimescale))
        )
        lastMappedPresentationTime = stepped
        return stepped
    }

    private func formatDescription(for pixelBuffer: CVPixelBuffer) -> CMVideoFormatDescription? {
        let key = PixelBufferFormatKey(
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer),
            pixelFormat: CVPixelBufferGetPixelFormatType(pixelBuffer),
            colorPrimaries: bufferAttachmentString(pixelBuffer, key: kCVImageBufferColorPrimariesKey),
            transferFunction: bufferAttachmentString(pixelBuffer, key: kCVImageBufferTransferFunctionKey),
            yCbCrMatrix: bufferAttachmentString(pixelBuffer, key: kCVImageBufferYCbCrMatrixKey)
        )

        if key == cachedFormatKey, let cachedFormatDescription {
            return cachedFormatDescription
        }

        var formatDescription: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        )
        guard status == noErr, let formatDescription else {
            MirageLogger.error(.renderer, "CMVideoFormatDescriptionCreateForImageBuffer failed: \(status)")
            return nil
        }

        cachedFormatKey = key
        cachedFormatDescription = formatDescription
        return formatDescription
    }

    private func bufferAttachmentString(_ buffer: CVBuffer, key: CFString) -> String? {
        CVBufferCopyAttachment(buffer, key, nil) as? String
    }

    private func registerFrameListener(for streamID: StreamID?) {
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

    private func unregisterFrameListener(for streamID: StreamID?) {
        guard let streamID else { return }
        MirageRenderStreamStore.shared.unregisterFrameListener(for: streamID, owner: self)
        MirageRenderStreamStore.shared.unregisterPresentationRecoveryHandler(for: streamID, owner: self)
        if listenerStreamID == streamID {
            listenerStreamID = nil
        }
    }

    private func refreshFrameListener(for streamID: StreamID) {
        unregisterFrameListener(for: listenerStreamID)
        registerFrameListener(for: streamID)
    }

    private func recoverDisplayLayerLivenessIfNeeded(
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
        resetPresentationState()
    }

    private func recoverDisplayLayerIfNeeded() {
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
        resetPresentationState(preserveLoggedLayerFailure: true)
    }

    private nonisolated static func isExpectedDisplayLayerFailure(_ error: Error?) -> Bool {
        guard let nsError = error as NSError? else { return false }
        guard nsError.domain == AVFoundationErrorDomain else { return false }
        return expectedDisplayLayerAVErrorCodes.contains(nsError.code)
    }

    private nonisolated static let expectedDisplayLayerAVErrorCodes: Set<Int> = [
        -11847, // AVErrorOperationInterrupted
        -11818, // AVErrorSessionWasInterrupted
    ]
}
