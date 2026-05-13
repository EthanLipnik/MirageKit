//
//  CaptureStreamOutput+StreamOutput.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/13/26.
//

import CoreMedia
import CoreVideo
import Dispatch
import Foundation
import MirageKit

#if os(macOS)
import ScreenCaptureKit

extension CaptureStreamOutput {
    /// Handles ScreenCaptureKit video and audio callbacks on the capture queue.
    func stream(_: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        #if DEBUG
        dispatchPrecondition(condition: .notOnQueue(.main))
        #endif
        let callbackStartTime = CFAbsoluteTimeGetCurrent()
        defer {
            let durationMs = (CFAbsoluteTimeGetCurrent() - callbackStartTime) * 1000
            recordCallbackDuration(durationMs)
        }

        let wallTime = CFAbsoluteTimeGetCurrent()
        let captureTime = wallTime

        if type == .audio {
            emitAudio(sampleBuffer: sampleBuffer)
            return
        }

        guard type == .screen else { return }
        recordRawScreenCallback(at: captureTime)

        let attachments =
            (CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer,
                createIfNecessary: false
            ) as? [[SCStreamFrameInfo: Any]])?.first
        let status = resolvedFrameStatus(from: attachments)
        let isValidSampleBuffer = CMSampleBufferIsValid(sampleBuffer)
        if let status {
            noteCaptureStartupSample(status: status)
            recordFrameStatus(status)
        } else if tracksFrameStatus, windowID == 0, isValidSampleBuffer {
            startupReadinessLock.withLock {
                startupReadinessState.hasObservedSample = true
            }
        }
        recordFrameTiming(displayTimeSeconds: resolvedDisplayTimeSeconds(from: attachments))

        guard isValidSampleBuffer,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }
        recordValidScreenSample()

        if !tracksFrameStatus {
            emitUntrackedFrame(
                sampleBuffer: sampleBuffer,
                pixelBuffer: pixelBuffer,
                attachments: attachments,
                status: status,
                captureTime: captureTime
            )
            return
        }

        emitTrackedFrame(
            sampleBuffer: sampleBuffer,
            pixelBuffer: pixelBuffer,
            attachments: attachments,
            status: status,
            captureTime: captureTime
        )
    }

    private func emitUntrackedFrame(
        sampleBuffer: CMSampleBuffer,
        pixelBuffer: CVPixelBuffer,
        attachments: [SCStreamFrameInfo: Any]?,
        status: SCFrameStatus?,
        captureTime: CFAbsoluteTime
    ) {
        if status == nil {
            noteCaptureStartupSample(status: .complete)
            recordFrameStatus(.complete)
        }
        recordRenderableScreenSample()
        updateDeliveryState(captureTime: captureTime, isComplete: true)

        if let shouldDropFrame, shouldDropFrame() {
            logAdmissionDrop()
            return
        }

        let bufferWidth = CVPixelBufferGetWidth(pixelBuffer)
        let bufferHeight = CVPixelBufferGetHeight(pixelBuffer)
        frameCount += 1
        if frameCount == 1 { MirageLogger.capture("Frame \(frameCount): \(bufferWidth)x\(bufferHeight)") }

        let frameInfo = CapturedFrameInfo(
            contentRect: fullBufferContentRect(bufferWidth: bufferWidth, bufferHeight: bufferHeight),
            dirtyPercentage: 100,
            isIdleFrame: false
        )
        emitFrame(
            sampleBuffer: sampleBuffer,
            sourcePixelBuffer: pixelBuffer,
            frameInfo: frameInfo,
            captureTime: captureTime,
            attachments: attachments
        )
    }

    private func emitTrackedFrame(
        sampleBuffer: CMSampleBuffer,
        pixelBuffer: CVPixelBuffer,
        attachments: [SCStreamFrameInfo: Any]?,
        status: SCFrameStatus?,
        captureTime: CFAbsoluteTime
    ) {
        var isIdleFrame = false
        if let status {
            let resolvedStatus = status
            if resolvedStatus == .idle {
                skippedIdleFrames += 1
                isIdleFrame = true
            }
            if resolvedStatus == .blank || resolvedStatus == .suspended { return }
        }

        let effectiveStatus = status ?? .complete
        if status == nil {
            noteCaptureStartupSample(status: effectiveStatus)
            recordFrameStatus(effectiveStatus)
        }
        guard effectiveStatus == .complete || effectiveStatus == .idle else { return }
        if effectiveStatus == .idle { isIdleFrame = true }
        recordRenderableScreenSample()

        updateDeliveryState(captureTime: captureTime, isComplete: effectiveStatus == .complete)

        if let shouldDropFrame, shouldDropFrame() {
            logAdmissionDrop()
            return
        }

        let bufferWidth = CVPixelBufferGetWidth(pixelBuffer)
        let bufferHeight = CVPixelBufferGetHeight(pixelBuffer)
        let fullRect = fullBufferContentRect(bufferWidth: bufferWidth, bufferHeight: bufferHeight)
        let contentRect = resolvedContentRect(
            fullRect: fullRect,
            bufferWidth: bufferWidth,
            bufferHeight: bufferHeight,
            attachments: attachments,
            isIdleFrame: isIdleFrame
        )

        let totalPixels = bufferWidth * bufferHeight
        let dirtyPercentage: Float = if isIdleFrame {
            0
        } else if totalPixels > 0 {
            100
        } else {
            0
        }

        frameCount += 1
        if frameCount == 1 { MirageLogger.capture("Frame \(frameCount): \(bufferWidth)x\(bufferHeight)") }

        let frameInfo = CapturedFrameInfo(
            contentRect: contentRect.isEmpty ? fullRect : contentRect,
            dirtyPercentage: dirtyPercentage,
            isIdleFrame: isIdleFrame
        )

        emitFrame(
            sampleBuffer: sampleBuffer,
            sourcePixelBuffer: pixelBuffer,
            frameInfo: frameInfo,
            captureTime: captureTime,
            attachments: attachments
        )
    }

    private func resolvedContentRect(
        fullRect: CGRect,
        bufferWidth: Int,
        bufferHeight: Int,
        attachments: [SCStreamFrameInfo: Any]?,
        isIdleFrame: Bool
    ) -> CGRect {
        var contentRect = fullRect
        let shouldReuseCachedContentRect = windowID == 0
        if usesDetailedMetadata,
           !isIdleFrame,
           let attachments,
           let contentRectValue = attachments[.contentRect] {
            let scaleFactor: CGFloat = if let scale = attachments[.scaleFactor] as? CGFloat {
                scale
            } else if let scale = attachments[.scaleFactor] as? Double {
                CGFloat(scale)
            } else if let scale = attachments[.scaleFactor] as? NSNumber {
                CGFloat(scale.doubleValue)
            } else {
                1.0
            }
            let contentRectDict = contentRectValue as! CFDictionary
            if let rect = CGRect(dictionaryRepresentation: contentRectDict) {
                let scaledRect = CGRect(
                    x: rect.origin.x * scaleFactor,
                    y: rect.origin.y * scaleFactor,
                    width: rect.width * scaleFactor,
                    height: rect.height * scaleFactor
                )
                if let normalizedRect = normalizedContentRect(
                    scaledRect,
                    bufferWidth: bufferWidth,
                    bufferHeight: bufferHeight
                ) {
                    contentRect = normalizedRect
                    lastContentRect = normalizedRect
                } else if shouldReuseCachedContentRect, !lastContentRect.isEmpty {
                    contentRect = lastContentRect
                } else if !shouldReuseCachedContentRect {
                    MirageLogger.debug(
                        .capture,
                        "Discarding invalid window contentRect \(scaledRect) for buffer \(bufferWidth)x\(bufferHeight); using full-frame rect"
                    )
                }
            } else if shouldReuseCachedContentRect, !lastContentRect.isEmpty {
                contentRect = lastContentRect
            }
        } else if shouldReuseCachedContentRect, !lastContentRect.isEmpty {
            contentRect = lastContentRect
        }
        return contentRect
    }
}

#endif
