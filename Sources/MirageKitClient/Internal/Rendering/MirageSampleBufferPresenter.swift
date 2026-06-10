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

@MainActor
final class MirageSampleBufferPresenter: @unchecked Sendable {
    private struct PreparedSampleBuffer {
        let sampleBuffer: CMSampleBuffer
        let mappedPresentationTime: CMTime
    }

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
    private var lastSubmittedCursor: MirageRenderCursor = .zero
    private var lastMappedPresentationTime: CMTime = .invalid
    private var scheduledTimebase: CMTimebase?
    private var usesScheduledTimebase = false
    var loggedLayerFailure = false
    var lastFrameSubmissionTime: CFTimeInterval = 0
    var displayLayerNotReadyStartTime: CFTimeInterval = 0
    var lastPendingFrameNotReadyLogTime: CFTimeInterval = 0
    #if os(iOS) || os(visionOS)
    private(set) var currentContentReferenceSize: CGSize?
    #endif

    var onFrameAvailable: (() -> Void)?
    var onPresentationRecoveryRequested: (() -> Void)?

    init(displayLayer: AVSampleBufferDisplayLayer) {
        self.displayLayer = displayLayer
    }

    isolated deinit {
        unregisterFrameListener(for: listenerStreamID)
    }

    var hasPendingFrameForCurrentPresenter: Bool {
        guard let streamID else { return false }
        return MirageRenderStreamStore.shared.hasFrameForPresentation(
            for: streamID,
            after: lastSubmittedCursor
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

    func resetPresentationState(
        preserveLoggedLayerFailure: Bool = false,
        removeDisplayedImage: Bool = true
    ) {
        cachedFormatKey = nil
        cachedFormatDescription = nil
        resetSequenceTrackingState()
        if !preserveLoggedLayerFailure {
            loggedLayerFailure = false
        }
        clearCurrentFrameState(removeDisplayedImage: removeDisplayedImage)
    }

    private func clearCurrentFrameState(removeDisplayedImage: Bool = true) {
        guard let displayLayer else { return }
        if removeDisplayedImage {
            displayLayer.flushAndRemoveImage()
            displayLayer.contentsRect = CGRect(x: 0, y: 0, width: 1, height: 1)
            #if os(iOS) || os(visionOS)
            currentContentReferenceSize = nil
            #endif
        } else {
            displayLayer.flush()
        }
        lastSubmittedCursor = .zero
        displayLayerNotReadyStartTime = 0
    }

    func submitPendingFrameIfPossible(referenceTime: CFTimeInterval) -> MirageRenderSubmissionResult {
        guard let streamID, let displayLayer else { return .blocked }
        guard !renderingSuspended else { return .blocked }
        recoverDisplayLayerIfNeeded()
        guard displayLayer.status != .failed else { return .blocked }

        let now = CACurrentMediaTime()
        rebaseSequenceTrackingIfNeeded(for: streamID)
        guard MirageRenderStreamStore.shared.hasFrameForPresentation(for: streamID, after: lastSubmittedCursor) else {
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
            after: lastSubmittedCursor
        ) else {
            if MirageRenderStreamStore.shared.pendingFrameCount(for: streamID) > 0 {
                logPendingFrameNotReadyIfNeeded(streamID: streamID, now: now)
                return .pendingFrameNotReady
            }
            return .noPendingFrame
        }

        if !frame.cursor.isAfter(lastSubmittedCursor) {
            let latestCursor = MirageRenderStreamStore.shared.latestCursor(for: streamID)
            if shouldRebaseSequenceTracking(latestCursor: latestCursor) {
                MirageLogger.renderer(
                    "Detected render sequence regression for stream \(streamID) (\(lastSubmittedCursor) -> \(latestCursor)); rebasing presenter state"
                )
                resetSequenceTrackingState()
                refreshFrameListener(for: streamID)
            }
            guard frame.cursor.isAfter(lastSubmittedCursor) else { return .noPendingFrame }
        }

        let pixelBuffer = presentationPixelBuffer(for: frame)
        let timing = MirageRenderStreamStore.shared.presentationTiming(for: streamID)
        guard let preparedSampleBuffer = makeSampleBuffer(
            from: pixelBuffer,
            timing: timing,
            referenceTime: referenceTime
        ) else {
            return .blocked
        }

        displayLayer.enqueue(preparedSampleBuffer.sampleBuffer)
        lastSubmittedCursor = frame.cursor
        lastFrameSubmissionTime = CACurrentMediaTime()
        displayLayerNotReadyStartTime = 0
        MirageRenderStreamStore.shared.markSubmitted(
            cursor: frame.cursor,
            remotePresentationTime: frame.remotePresentationTime.isValid ? frame.remotePresentationTime : frame.presentationTime,
            mappedPresentationTime: preparedSampleBuffer.mappedPresentationTime,
            for: streamID
        )
        return .submitted
    }

    private func rebaseSequenceTrackingIfNeeded(for streamID: StreamID) {
        guard lastSubmittedCursor.hasSubmittedFrame else { return }
        let latestCursor = MirageRenderStreamStore.shared.latestCursor(for: streamID)
        guard shouldRebaseSequenceTracking(latestCursor: latestCursor),
              MirageRenderStreamStore.shared.pendingFrameCount(for: streamID) > 0 else {
            return
        }
        MirageLogger.renderer(
            "Detected render sequence regression for stream \(streamID) (\(lastSubmittedCursor) -> \(latestCursor)); rebasing presenter state"
        )
        resetSequenceTrackingState()
        refreshFrameListener(for: streamID)
    }

    private func shouldRebaseSequenceTracking(latestCursor: MirageRenderCursor) -> Bool {
        guard latestCursor.hasSubmittedFrame else { return false }
        if latestCursor.generation > lastSubmittedCursor.generation {
            return true
        }
        guard latestCursor.generation == lastSubmittedCursor.generation else { return false }
        return latestCursor.sequence < lastSubmittedCursor.sequence
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
        lastSubmittedCursor = .zero
        lastMappedPresentationTime = .invalid
        lastFrameSubmissionTime = 0
        displayLayerNotReadyStartTime = 0
        lastPendingFrameNotReadyLogTime = 0
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
    ) -> PreparedSampleBuffer? {
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

        if timing.displaysImmediately {
            disableScheduledTimebaseIfNeeded()
            CMSetAttachment(
                sampleBuffer,
                key: kCMSampleAttachmentKey_DisplayImmediately,
                value: kCFBooleanTrue,
                attachmentMode: kCMAttachmentMode_ShouldNotPropagate
            )
        } else {
            guard enableScheduledTimebaseIfNeeded() else { return nil }
        }

        return PreparedSampleBuffer(
            sampleBuffer: sampleBuffer,
            mappedPresentationTime: samplePresentationTime
        )
    }

    private func enableScheduledTimebaseIfNeeded() -> Bool {
        guard let displayLayer else { return false }
        if scheduledTimebase == nil {
            let hostClock = CMClockGetHostTimeClock()
            var createdTimebase: CMTimebase?
            let status = CMTimebaseCreateWithSourceClock(
                allocator: kCFAllocatorDefault,
                sourceClock: hostClock,
                timebaseOut: &createdTimebase
            )
            guard status == noErr, let createdTimebase else {
                MirageLogger.error(.renderer, "CMTimebaseCreateWithSourceClock failed: \(status)")
                return false
            }
            CMTimebaseSetTime(createdTimebase, time: CMClockGetTime(hostClock))
            CMTimebaseSetRate(createdTimebase, rate: 1)
            scheduledTimebase = createdTimebase
        }
        displayLayer.controlTimebase = scheduledTimebase
        usesScheduledTimebase = true
        return true
    }

    private func disableScheduledTimebaseIfNeeded() {
        guard usesScheduledTimebase else { return }
        displayLayer?.controlTimebase = nil
        usesScheduledTimebase = false
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
            minimumStep: timing.minimumMonotonicPresentationStep
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
