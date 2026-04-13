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

    private weak var displayLayer: AVSampleBufferDisplayLayer?

    private var streamID: StreamID?
    private var listenerStreamID: StreamID?
    private var maxRenderFPS: Int = 60
    private var renderingSuspended = false

    private var cachedFormatKey: PixelBufferFormatKey?
    private var cachedFormatDescription: CMVideoFormatDescription?
    private var lastSubmittedSequence: UInt64 = 0
    private var remotePresentationOrigin: CMTime?
    private var localPresentationOrigin: CFTimeInterval?
    private var lastMappedPresentationTime: CMTime = .invalid
    private var loggedLayerFailure = false
    private var lastFrameSubmissionTime: CFTimeInterval = 0
    private(set) var currentContentReferenceSize: CGSize?

    var onFrameAvailable: (() -> Void)?

    init(displayLayer: AVSampleBufferDisplayLayer) {
        self.displayLayer = displayLayer
    }

    deinit {
        unregisterFrameListener(for: listenerStreamID)
    }

    var hasDisplayLayerFailure: Bool {
        displayLayer?.status == .failed
    }

    func setTargetFPS(_ fps: Int) {
        let normalized = MirageRenderModePolicy.normalizedTargetFPS(fps)
        maxRenderFPS = normalized
        if let streamID {
            MirageRenderStreamStore.shared.setTargetFPS(for: streamID, targetFPS: normalized)
        }
    }

    func setStreamID(_ newStreamID: StreamID?) {
        guard newStreamID != streamID else { return }
        unregisterFrameListener(for: streamID)
        streamID = newStreamID
        registerFrameListener(for: newStreamID)
        if let newStreamID {
            MirageRenderStreamStore.shared.setTargetFPS(for: newStreamID, targetFPS: maxRenderFPS)
        }
        resetPresentationState()
    }

    func setRenderingSuspended(_ suspended: Bool, clearCurrentFrame: Bool) {
        renderingSuspended = suspended
        guard suspended else { return }
        guard clearCurrentFrame else { return }
        clearCurrentFrameState()
    }

    func resetPresentationState() {
        cachedFormatKey = nil
        cachedFormatDescription = nil
        resetSequenceTrackingState()
        loggedLayerFailure = false
        clearCurrentFrameState()
    }

    private func clearCurrentFrameState() {
        guard let displayLayer else { return }
        displayLayer.flushAndRemoveImage()
        displayLayer.contentsRect = CGRect(x: 0, y: 0, width: 1, height: 1)
        currentContentReferenceSize = nil
        lastSubmittedSequence = 0
    }

    @discardableResult
    func submitPendingFrameIfPossible(referenceTime: CFTimeInterval) -> Bool {
        guard let streamID, let displayLayer else { return false }
        guard !renderingSuspended else { return false }
        recoverDisplayLayerIfNeeded()
        guard displayLayer.status != .failed else { return false }

        // Detect presentation stalls (backpressure, display sleep, window occlusion)
        // and rebase time mapping to prevent fast-forward playback on recovery
        let now = CACurrentMediaTime()
        if lastFrameSubmissionTime > 0, (now - lastFrameSubmissionTime) > Self.stallRecoveryThresholdSeconds {
            MirageLogger.renderer(
                "Presentation stall detected (\(String(format: "%.2f", now - lastFrameSubmissionTime))s gap); rebasing time origin"
            )
            resetSequenceTrackingState()
        }

        guard displayLayer.isReadyForMoreMediaData else {
            MirageRenderStreamStore.shared.noteDisplayLayerNotReady(for: streamID)
            return false
        }
        guard let frame = MirageRenderStreamStore.shared.takePendingFrame(for: streamID) else {
            return false
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
            guard frame.sequence > lastSubmittedSequence else { return false }
        }

        updateLayerContentRect(frame.contentRect, pixelBuffer: frame.pixelBuffer)
        guard let (sampleBuffer, mappedPresentationTime) = makeSampleBuffer(
            from: frame.pixelBuffer,
            presentationTime: frame.presentationTime,
            referenceTime: referenceTime
        ) else {
            return false
        }

        displayLayer.enqueue(sampleBuffer)
        lastSubmittedSequence = frame.sequence
        lastFrameSubmissionTime = CACurrentMediaTime()
        MirageRenderStreamStore.shared.markSubmitted(
            sequence: frame.sequence,
            mappedPresentationTime: mappedPresentationTime,
            for: streamID
        )
        return true
    }

    private func resetSequenceTrackingState() {
        lastSubmittedSequence = 0
        remotePresentationOrigin = nil
        localPresentationOrigin = nil
        lastMappedPresentationTime = .invalid
        lastFrameSubmissionTime = 0
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
    }

    private func unregisterFrameListener(for streamID: StreamID?) {
        guard let streamID else { return }
        MirageRenderStreamStore.shared.unregisterFrameListener(for: streamID, owner: self)
        if listenerStreamID == streamID {
            listenerStreamID = nil
        }
    }

    private func refreshFrameListener(for streamID: StreamID) {
        unregisterFrameListener(for: listenerStreamID)
        registerFrameListener(for: streamID)
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
        displayLayer.flushAndRemoveImage()
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
