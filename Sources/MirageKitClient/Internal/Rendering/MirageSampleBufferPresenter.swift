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
import Dispatch
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

        func matchesBase(_ metadata: MirageRenderFramePresentationMetadata) -> Bool {
            width == metadata.pixelWidth &&
                height == metadata.pixelHeight &&
                pixelFormat == metadata.pixelFormat
        }
    }

    static let cmTimeScale: CMTimeScale = 1_000_000_000
    static let displayLayerLivenessResetThresholdSeconds: CFTimeInterval = 0.75

    private weak var displayLayer: AVSampleBufferDisplayLayer?
    private let sampleBufferRenderer: AVSampleBufferVideoRenderer
    private let rendererReadinessQueue: DispatchQueue?
    private let pixelBufferCropper = MiragePixelBufferCropper()

    private var streamID: StreamID?
    private var listenerStreamID: StreamID?
    private var maxRenderFPS: Int = 60
    private var renderingSuspended = false
    private var contentRectOverride: CGRect?

    private var cachedFormatKey: PixelBufferFormatKey?
    private var cachedFormatDescription: CMVideoFormatDescription?
    private var lastSubmittedCursor: MirageRenderCursor = .zero
    private var lastMappedPresentationTime: CMTime = .invalid
    private var lastAppliedContentsRect: CGRect?
    private var loggedLayerFailure = false
    private var lastFrameSubmissionTime: CFTimeInterval = 0
    private var displayLayerNotReadyStartTime: CFTimeInterval = 0
    private var rendererReadyCallbackArmed = false
    private(set) var currentContentReferenceSize: CGSize?

    var onFrameAvailable: (@Sendable () -> Void)?
    var onPresentationRecoveryRequested: (@Sendable () -> Void)?
    var onRendererReadyForMoreMediaData: (@Sendable () -> Void)?

    init(displayLayer: AVSampleBufferDisplayLayer, rendererReadinessQueue: DispatchQueue? = nil) {
        self.displayLayer = displayLayer
        sampleBufferRenderer = displayLayer.sampleBufferRenderer
        self.rendererReadinessQueue = rendererReadinessQueue
    }

    deinit {
        cancelRendererReadyCallback()
        unregisterFrameListener(for: listenerStreamID)
    }

    var hasDisplayLayerFailure: Bool {
        sampleBufferRenderer.status == .failed
    }

    var hasPendingFrameForCurrentPresenter: Bool {
        guard let streamID else { return false }
        return MirageRenderStreamStore.shared.hasFrameForPresentation(
            for: streamID,
            after: resolvedSubmittedCursor(for: streamID)
        )
    }

    var pendingFrameCountForCurrentPresenter: Int {
        guard let streamID else { return 0 }
        return MirageRenderStreamStore.shared.pendingFrameCount(
            for: streamID,
            after: resolvedSubmittedCursor(for: streamID)
        )
    }

    func setTargetFPS(_ fps: Int) {
        let normalized = MirageRenderModePolicy.normalizedTargetFPS(fps)
        maxRenderFPS = normalized
        if let streamID {
            MirageRenderStreamStore.shared.setDisplayTargetFPS(for: streamID, displayFPS: normalized)
        }
    }

    func setCadenceTarget(_ target: MirageStreamCadenceTarget) {
        maxRenderFPS = target.displayFPS
        if let streamID {
            MirageRenderStreamStore.shared.setCadenceTarget(for: streamID, target: target)
        }
    }

    func setStreamID(_ newStreamID: StreamID?) {
        if newStreamID == streamID {
            registerFrameListener(for: newStreamID)
            if let newStreamID {
                MirageRenderStreamStore.shared.setDisplayTargetFPS(for: newStreamID, displayFPS: maxRenderFPS)
            }
            return
        }
        unregisterFrameListener(for: streamID)
        streamID = newStreamID
        registerFrameListener(for: newStreamID)
        if let newStreamID {
            MirageRenderStreamStore.shared.setDisplayTargetFPS(for: newStreamID, displayFPS: maxRenderFPS)
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
        cancelRendererReadyCallback()
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
        cancelRendererReadyCallback()
        sampleBufferRenderer.flush()
        flushDisplayLayerImageIfNeeded()
        applyLayerContentsRect(CGRect(x: 0, y: 0, width: 1, height: 1), to: displayLayer)
        currentContentReferenceSize = nil
        lastSubmittedCursor = baselineCursorForCurrentStream()
        displayLayerNotReadyStartTime = 0
    }

    @discardableResult
    func submitPendingFrameIfPossible(
        referenceTime: CFTimeInterval,
        source: MirageRenderSubmissionSource = .scheduled
    ) -> MirageRenderSubmissionResult {
        guard let streamID else { return .blocked }
        var submittedFrames = 0
        let allowsMultipleFrames = MirageRenderStreamStore.shared.allowsMultipleFramePresentationPass(for: streamID)
        defer {
            MirageRenderStreamStore.shared.notePresentationPass(
                for: streamID,
                framesSubmitted: submittedFrames
            )
            if source == .rendererReady {
                MirageRenderStreamStore.shared.noteRendererReadyDrainPass(
                    for: streamID,
                    submittedFrames: submittedFrames,
                    rearmed: rendererReadyCallbackArmed
                )
            }
        }

        while true {
            let result = submitNextPendingFrameIfPossible(
                streamID: streamID,
                referenceTime: referenceTime
            )

            switch result {
            case .submitted:
                submittedFrames += 1
                guard allowsMultipleFrames else {
                    return .submitted
                }
                guard !MirageRenderStreamStore.shared.shouldPreserveSmoothestPacingFrame(
                    for: streamID,
                    after: lastSubmittedCursor
                ) else {
                    return .submitted
                }
            case .noPendingFrame:
                return submittedFrames > 0 ? .submitted : .noPendingFrame
            case .displayLayerNotReady:
                return .displayLayerNotReady
            case .blocked:
                return submittedFrames > 0 ? .submitted : .blocked
            }
        }
    }

    private struct MainThreadDisplayLayerReference: @unchecked Sendable {
        let displayLayer: AVSampleBufferDisplayLayer
    }

    private func submitNextPendingFrameIfPossible(
        streamID: StreamID,
        referenceTime: CFTimeInterval
    ) -> MirageRenderSubmissionResult {
        guard !renderingSuspended else { return .blocked }
        recoverDisplayLayerIfNeeded()
        guard sampleBufferRenderer.status != .failed else { return .blocked }

        let now = CACurrentMediaTime()
        let submittedCursor = resolvedSubmittedCursor(for: streamID)
        guard MirageRenderStreamStore.shared.hasFrameForPresentation(for: streamID, after: submittedCursor) else {
            return .noPendingFrame
        }

        MirageRenderStreamStore.shared.notePresentationEligibleFrame(for: streamID)
        MirageRenderStreamStore.shared.noteSubmitAttempt(for: streamID)
        guard sampleBufferRenderer.isReadyForMoreMediaData else {
            MirageRenderStreamStore.shared.noteDisplayLayerNotReady(for: streamID)
            MirageRenderStreamStore.shared.noteSampleBufferRendererNotReady(for: streamID)
            armRendererReadyCallback()
            recoverDisplayLayerLivenessIfNeeded(now: now, presenterHasPendingFrame: true)
            return .displayLayerNotReady
        }
        cancelRendererReadyCallback()
        displayLayerNotReadyStartTime = 0

        guard let frame = MirageRenderStreamStore.shared.frameForPresentation(
            for: streamID,
            after: submittedCursor
        ) else {
            return .noPendingFrame
        }

        guard frame.cursor.isAfter(submittedCursor) else { return .noPendingFrame }
        if frame.cursor.generation != submittedCursor.generation {
            resetTimingForGenerationBoundary(
                streamID: streamID,
                generation: frame.cursor.generation,
                reason: "render-generation-boundary"
            )
        }

        let presentationFrame = presentationPixelBuffer(for: frame)
        let timing = MirageRenderStreamStore.shared.presentationTiming(for: streamID)
        let displayImmediately = MirageRenderStreamStore.shared.shouldDisplayFrameImmediately(
            for: streamID,
            cursor: frame.cursor
        )
        guard let (sampleBuffer, mappedPresentationTime) = makeSampleBuffer(
            from: presentationFrame.pixelBuffer,
            metadata: presentationFrame.metadata,
            timing: timing,
            referenceTime: referenceTime,
            displayImmediately: displayImmediately
        ) else {
            return .blocked
        }

        sampleBufferRenderer.enqueue(sampleBuffer)
        if displayImmediately {
            MirageRenderStreamStore.shared.noteDisplayImmediateSubmission(for: streamID)
        }
        lastSubmittedCursor = frame.cursor
        lastFrameSubmissionTime = CACurrentMediaTime()
        displayLayerNotReadyStartTime = 0
        MirageRenderStreamStore.shared.markSubmitted(
            cursor: frame.cursor,
            remotePresentationTime: frame.remotePresentationTime.isValid ? frame.remotePresentationTime : frame.presentationTime,
            mappedPresentationTime: mappedPresentationTime,
            presentedFrameIdentity: MirageRenderStreamStore.PresentedFrameIdentity(frame: frame),
            for: streamID
        )
        return .submitted
    }

    private func presentationPixelBuffer(
        for frame: MirageRenderFrame
    ) -> (pixelBuffer: CVPixelBuffer, metadata: MirageRenderFramePresentationMetadata?) {
        guard let contentRectOverride else {
            updateLayerContentRect(frame.presentationMetadata)
            return (frame.pixelBuffer, frame.presentationMetadata)
        }

        guard let cropResult = pixelBufferCropper.crop(frame.pixelBuffer, to: contentRectOverride) else {
            updateLayerContentRect(contentRectOverride, pixelBuffer: frame.pixelBuffer)
            return (frame.pixelBuffer, nil)
        }

        resetLayerContentRect(to: cropResult.contentRect)
        return (cropResult.pixelBuffer, nil)
    }

    private func resetSequenceTrackingState() {
        lastSubmittedCursor = baselineCursorForCurrentStream()
        lastMappedPresentationTime = .invalid
        lastFrameSubmissionTime = 0
        displayLayerNotReadyStartTime = 0
    }

    private func resetTimingForGenerationBoundary(
        streamID: StreamID,
        generation: UInt64,
        reason: String
    ) {
        cancelRendererReadyCallback()
        sampleBufferRenderer.flush()
        flushDisplayLayerImageIfNeeded()
        cachedFormatKey = nil
        cachedFormatDescription = nil
        lastSubmittedCursor = MirageRenderCursor(generation: generation, sequence: 0)
        lastMappedPresentationTime = .invalid
        lastFrameSubmissionTime = 0
        displayLayerNotReadyStartTime = 0
        MirageRenderStreamStore.shared.recordPresenterTimingReset(for: streamID, reason: reason)
        MirageLogger.renderer(
            "Presentation timing reset for stream \(streamID) at render generation \(generation) (\(reason))"
        )
    }

    private func resolvedSubmittedCursor(for streamID: StreamID) -> MirageRenderCursor {
        let generation = MirageRenderStreamStore.shared.currentGeneration(for: streamID)
        guard lastSubmittedCursor.generation == generation else {
            return MirageRenderCursor(generation: generation, sequence: 0)
        }
        return lastSubmittedCursor
    }

    private func baselineCursorForCurrentStream() -> MirageRenderCursor {
        guard let streamID else { return .zero }
        return MirageRenderStreamStore.shared.baselineCursor(for: streamID)
    }

    private func updateLayerContentRect(_ contentRect: CGRect, pixelBuffer: CVPixelBuffer) {
        let width = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let height = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        guard width > 0, height > 0 else {
            applyLayerContentsRect(CGRect(x: 0, y: 0, width: 1, height: 1), to: displayLayer)
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
        applyLayerContentsRect(normalized, to: displayLayer)
    }

    private func updateLayerContentRect(_ metadata: MirageRenderFramePresentationMetadata) {
        currentContentReferenceSize = metadata.contentReferenceSize
        applyLayerContentsRect(metadata.normalizedContentRect, to: displayLayer)
    }

    private func resetLayerContentRect(to contentRect: CGRect) {
        applyLayerContentsRect(CGRect(x: 0, y: 0, width: 1, height: 1), to: displayLayer)
        currentContentReferenceSize = contentRect.size
    }

    private func applyLayerContentsRect(_ rect: CGRect, to displayLayer: AVSampleBufferDisplayLayer?) {
        guard lastAppliedContentsRect != rect else { return }
        guard let displayLayer else {
            lastAppliedContentsRect = rect
            return
        }
        let displayLayerReference = MainThreadDisplayLayerReference(displayLayer: displayLayer)
        applyDisplayLayerMutation {
            displayLayerReference.displayLayer.contentsRect = rect
        }
        lastAppliedContentsRect = rect
    }

    private func flushDisplayLayerImageIfNeeded() {
        guard let displayLayer else { return }
        let displayLayerReference = MainThreadDisplayLayerReference(displayLayer: displayLayer)
        applyDisplayLayerMutation {
            displayLayerReference.displayLayer.flushAndRemoveImage()
        }
    }

    private func applyDisplayLayerMutation(_ mutation: @escaping @Sendable () -> Void) {
        if Thread.isMainThread {
            mutation()
        } else {
            DispatchQueue.main.async(execute: mutation)
        }
    }

    private func armRendererReadyCallback() {
        guard !rendererReadyCallbackArmed else { return }
        guard let rendererReadinessQueue else { return }
        rendererReadyCallbackArmed = true
        sampleBufferRenderer.requestMediaDataWhenReady(on: rendererReadinessQueue) { [weak self] in
            self?.handleRendererReadyForMoreMediaData()
        }
    }

    private func handleRendererReadyForMoreMediaData() {
        guard rendererReadyCallbackArmed else { return }
        guard sampleBufferRenderer.isReadyForMoreMediaData else { return }
        rendererReadyCallbackArmed = false
        sampleBufferRenderer.stopRequestingMediaData()
        onRendererReadyForMoreMediaData?()
    }

    private func cancelRendererReadyCallback() {
        guard rendererReadyCallbackArmed else { return }
        rendererReadyCallbackArmed = false
        sampleBufferRenderer.stopRequestingMediaData()
    }

    private func makeSampleBuffer(
        from pixelBuffer: CVPixelBuffer,
        metadata: MirageRenderFramePresentationMetadata?,
        timing: MirageRenderPresentationTiming,
        referenceTime: CFTimeInterval,
        displayImmediately: Bool
    ) -> (sampleBuffer: CMSampleBuffer, mappedPresentationTime: CMTime)? {
        guard let formatDescription = formatDescription(for: pixelBuffer, metadata: metadata) else { return nil }

        let samplePresentationTime = mappedPresentationTime(
            referenceTime: referenceTime,
            timing: timing
        )

        var sampleTiming = CMSampleTimingInfo(
            duration: timing.frameDuration,
            presentationTimeStamp: samplePresentationTime,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &sampleTiming,
            sampleBufferOut: &sampleBuffer
        )

        guard status == noErr, let sampleBuffer else {
            MirageLogger.error(.renderer, "CMSampleBufferCreateReadyWithImageBuffer failed: \(status)")
            return nil
        }

        if displayImmediately {
            applyDisplayImmediatelyAttachment(to: sampleBuffer)
        }

        return (sampleBuffer, samplePresentationTime)
    }

    private func applyDisplayImmediatelyAttachment(to sampleBuffer: CMSampleBuffer) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: true
        ) as? [NSMutableDictionary],
            let attachment = attachments.first else {
            return
        }
        attachment[kCMSampleAttachmentKey_DisplayImmediately] = kCFBooleanTrue
    }

    private func mappedPresentationTime(
        referenceTime: CFTimeInterval,
        timing: MirageRenderPresentationTiming
    ) -> CMTime {
        let scheduledTime = timing.presentationTime(
            referenceTime: referenceTime,
            timescale: Self.cmTimeScale
        )
        return makeMonotonicPresentationTime(
            from: scheduledTime,
            minimumStep: timing.frameDuration
        )
    }

    private func makeMonotonicPresentationTime(from candidate: CMTime, minimumStep: CMTime) -> CMTime {
        guard lastMappedPresentationTime.isValid else {
            lastMappedPresentationTime = candidate
            return candidate
        }

        let minimumPresentationTime = CMTimeAdd(lastMappedPresentationTime, minimumStep)
        if CMTimeCompare(candidate, minimumPresentationTime) >= 0 {
            lastMappedPresentationTime = candidate
            return candidate
        }

        lastMappedPresentationTime = minimumPresentationTime
        return minimumPresentationTime
    }

    private func formatDescription(
        for pixelBuffer: CVPixelBuffer,
        metadata: MirageRenderFramePresentationMetadata?
    ) -> CMVideoFormatDescription? {
        if let metadata,
           let cachedFormatKey,
           cachedFormatKey.matchesBase(metadata),
           let cachedFormatDescription {
            return cachedFormatDescription
        }

        let key = PixelBufferFormatKey(
            width: metadata?.pixelWidth ?? CVPixelBufferGetWidth(pixelBuffer),
            height: metadata?.pixelHeight ?? CVPixelBufferGetHeight(pixelBuffer),
            pixelFormat: metadata?.pixelFormat ?? CVPixelBufferGetPixelFormatType(pixelBuffer),
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
            self.onFrameAvailable?()
        }
        if onPresentationRecoveryRequested != nil {
            MirageRenderStreamStore.shared.registerPresentationRecoveryHandler(for: streamID, owner: self) { [weak self] in
                guard let self else { return }
                self.onPresentationRecoveryRequested?()
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
        if let streamID {
            MirageRenderStreamStore.shared.recordDisplayLayerLivenessReset(
                for: streamID,
                reason: "not-ready-pending-frame"
            )
        }
        resetPresentationState()
    }

    private func recoverDisplayLayerIfNeeded() {
        guard sampleBufferRenderer.status == .failed else { return }
        if !loggedLayerFailure {
            if Self.isExpectedDisplayLayerFailure(sampleBufferRenderer.error) {
                let description = sampleBufferRenderer.error?.localizedDescription ?? "unknown error"
                MirageLogger.renderer("AVSampleBufferDisplayLayer interruption during teardown: \(description)")
            } else {
                let description = sampleBufferRenderer.error?.localizedDescription ?? "unknown error"
                MirageLogger.error(.renderer, "AVSampleBufferDisplayLayer failure: \(description)")
            }
            loggedLayerFailure = true
        }
        if let streamID {
            MirageRenderStreamStore.shared.recordDisplayLayerLivenessReset(
                for: streamID,
                reason: "layer-failed"
            )
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
