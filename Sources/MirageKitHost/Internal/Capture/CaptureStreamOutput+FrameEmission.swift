//
//  CaptureStreamOutput+FrameEmission.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/13/26.
//

import CoreMedia
import CoreVideo
import Foundation

#if os(macOS)
import ScreenCaptureKit

extension CaptureStreamOutput {
    /// Emits a video frame after cadence admission and delivery accounting.
    func emitFrame(
        sampleBuffer: CMSampleBuffer,
        sourcePixelBuffer: CVPixelBuffer,
        frameInfo: CapturedFrameInfo,
        captureTime: CFAbsoluteTime,
        attachments: [SCStreamFrameInfo: Any]?
    ) {
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let cadenceTimestamp = resolvedCadenceTimestamp(
            presentationTime: presentationTime,
            attachments: attachments,
            captureTime: captureTime
        )
        if shouldDropForTargetCadence(
            cadenceTimestamp: cadenceTimestamp,
            captureTime: captureTime,
            isIdleFrame: frameInfo.isIdleFrame
        ) {
            logCadenceDrop()
            return
        }
        recordCadenceAdmittedFrame()

        let duration = CMSampleBufferGetDuration(sampleBuffer)
        let frame = CapturedFrame(
            pixelBuffer: sourcePixelBuffer,
            presentationTime: presentationTime,
            duration: duration,
            captureTime: captureTime,
            info: frameInfo,
            backingSampleBuffer: sampleBuffer
        )
        recordDeliveredFrame(at: captureTime)
        onFrame(frame)
    }
}

#endif
