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
    static let displayLayerLivenessResetThresholdSeconds: CFTimeInterval = 0.75

    weak var displayLayer: AVSampleBufferDisplayLayer?
    private let pixelBufferCropper = MiragePixelBufferCropper()

    private var streamID: StreamID?
    var listenerStreamID: StreamID?
    private var maxRenderFPS: Int = 60
    private var renderingSuspended = false
    private var contentRectOverride: CGRect?

    private var cachedFormatKey: PixelBufferFormatKey?
    private var cachedFormatDescription: CMVideoFormatDescription?
    private var lastSubmittedSequence: UInt64 = 0
    private var lastMappedPresentationTime: CMTime = .invalid
    var loggedLayerFailure = false
    var lastFrameSubmissionTime: CFTimeInterval = 0
    var displayLayerNotReadyStartTime: CFTimeInterval = 0
    #if os(iOS) || os(visionOS)
    private(set) var currentContentReferenceSize: CGSize?
    #endif

    var onFrameAvailable: (() -> Void)?
    var onPresentationRecoveryRequested: (() -> Void)?

    init(displayLayer: AVSampleBufferDisplayLayer) {
        self.displayLayer = displayLayer
    }

    deinit {
        unregisterFrameListener(for: listenerStreamID)
    }

    var hasPendingFrameForCurrentPresenter: Bool {
        guard let streamID else { return false }
        return MirageRenderStreamStore.shared.hasFrameForPresentation(
            for: streamID,
            after: lastSubmittedSequence
        )
    }

    #if os(iOS) || os(visionOS)
    var hasDisplayLayerFailure: Bool {
        displayLayer?.status == .failed
    }
    #endif

    func setTargetFPS(_ fps: Int) {
        let normalized = MirageRenderModePolicy.normalizedTargetFPS(fps)
        maxRenderFPS = normalized
        if let streamID {
            MirageRenderStreamStore.shared.setDisplayTargetFPS(for: streamID, displayFPS: normalized)
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
        #if os(iOS) || os(visionOS)
        currentContentReferenceSize = nil
        #endif
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
        #if os(iOS) || os(visionOS)
        currentContentReferenceSize = nil
        #endif
        lastSubmittedSequence = 0
        displayLayerNotReadyStartTime = 0
    }

    func submitPendingFrameIfPossible(referenceTime: CFTimeInterval) -> MirageRenderSubmissionResult {
        guard let streamID, let displayLayer else { return .blocked }
        guard !renderingSuspended else { return .blocked }
        recoverDisplayLayerIfNeeded()
        guard displayLayer.status != .failed else { return .blocked }

        let now = CACurrentMediaTime()
        rebaseSequenceTrackingIfNeeded(for: streamID)
        guard MirageRenderStreamStore.shared.hasFrameForPresentation(for: streamID, after: lastSubmittedSequence) else {
            return .noPendingFrame
        }

        MirageRenderStreamStore.shared.noteSubmitAttempt(for: streamID)
        guard displayLayer.isReadyForMoreMediaData else {
            MirageRenderStreamStore.shared.noteDisplayLayerNotReady(for: streamID)
            recoverDisplayLayerLivenessIfNeeded(now: now, presenterHasPendingFrame: true)
            return .displayLayerNotReady
        }
        displayLayerNotReadyStartTime = 0

        guard let frame = MirageRenderStreamStore.shared.frameForPresentation(
            for: streamID,
            after: lastSubmittedSequence
        ) else {
            return .noPendingFrame
        }

        if frame.sequence <= lastSubmittedSequence {
            let latestSequence = MirageRenderStreamStore.shared.latestSequence(for: streamID)
            if latestSequence > 0, latestSequence <= lastSubmittedSequence {
                MirageLogger.renderer(
                    "Detected render sequence regression for stream \(streamID) (\(lastSubmittedSequence) -> \(latestSequence)); rebasing presenter state"
                )
                resetSequenceTrackingState()
                refreshFrameListener(for: streamID)
            }
            guard frame.sequence > lastSubmittedSequence else { return .noPendingFrame }
        }

        let pixelBuffer = presentationPixelBuffer(for: frame)
        let timing = MirageRenderStreamStore.shared.presentationTiming(for: streamID)
        guard let sampleBuffer = makeSampleBuffer(
            from: pixelBuffer,
            timing: timing,
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
            remotePresentationTime: frame.remotePresentationTime.isValid ? frame.remotePresentationTime : frame.presentationTime,
            for: streamID
        )
        return .submitted
    }

    private func rebaseSequenceTrackingIfNeeded(for streamID: StreamID) {
        guard lastSubmittedSequence > 0 else { return }
        let latestSequence = MirageRenderStreamStore.shared.latestSequence(for: streamID)
        guard latestSequence > 0,
              latestSequence <= lastSubmittedSequence,
              MirageRenderStreamStore.shared.pendingFrameCount(for: streamID) > 0 else {
            return
        }
        MirageLogger.renderer(
            "Detected render sequence regression for stream \(streamID) (\(lastSubmittedSequence) -> \(latestSequence)); rebasing presenter state"
        )
        resetSequenceTrackingState()
        refreshFrameListener(for: streamID)
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
            #if os(iOS) || os(visionOS)
            currentContentReferenceSize = nil
            #endif
            return
        }

        let resolvedContentRect: CGRect
        if contentRect.width > 0, contentRect.height > 0 {
            resolvedContentRect = contentRect
        } else {
            resolvedContentRect = CGRect(x: 0, y: 0, width: width, height: height)
        }
        #if os(iOS) || os(visionOS)
        currentContentReferenceSize = resolvedContentRect.size
        #endif

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
        #if os(iOS) || os(visionOS)
        currentContentReferenceSize = contentRect.size
        #endif
    }

    private func makeSampleBuffer(
        from pixelBuffer: CVPixelBuffer,
        timing: MirageRenderPresentationTiming,
        referenceTime: CFTimeInterval
    ) -> CMSampleBuffer? {
        guard let formatDescription = formatDescription(for: pixelBuffer) else { return nil }

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

        return sampleBuffer
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

    private func formatDescription(for pixelBuffer: CVPixelBuffer) -> CMVideoFormatDescription? {
        let key = PixelBufferFormatKey(
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer),
            pixelFormat: CVPixelBufferGetPixelFormatType(pixelBuffer),
            colorPrimaries: MirageCVBufferAttachments.string(pixelBuffer, key: kCVImageBufferColorPrimariesKey),
            transferFunction: MirageCVBufferAttachments.string(pixelBuffer, key: kCVImageBufferTransferFunctionKey),
            yCbCrMatrix: MirageCVBufferAttachments.string(pixelBuffer, key: kCVImageBufferYCbCrMatrixKey)
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

}
