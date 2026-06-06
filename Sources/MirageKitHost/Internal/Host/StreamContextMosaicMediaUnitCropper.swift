//
//  StreamContextMosaicMediaUnitCropper.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 6/6/26.
//

import CoreGraphics
import CoreMedia
import CoreVideo
import MirageKitClientPresentation

#if os(macOS)

final class StreamContextMosaicMediaUnitCropper: @unchecked Sendable {
    private let cropper = MiragePixelBufferCropper()

    func reset() {
        cropper.reset()
    }

    func crop(
        _ source: CVPixelBuffer,
        unit: StreamContextMosaicMediaUnitWorkItem
    ) -> MiragePixelBufferCropResult? {
        cropper.crop(source, to: unit.sourceCGRect, allowInvalidCropFallback: false)
    }

    func croppedFrame(
        from frame: CapturedFrame,
        unit: StreamContextMosaicMediaUnitWorkItem
    ) -> CapturedFrame? {
        guard let result = crop(frame.pixelBuffer, unit: unit) else { return nil }
        return CapturedFrame(
            pixelBuffer: result.pixelBuffer,
            presentationTime: frame.presentationTime,
            duration: frame.duration,
            captureTime: frame.captureTime,
            info: CapturedFrameInfo(
                contentRect: result.contentRect,
                dirtyPercentage: frame.info.dirtyPercentage,
                isIdleFrame: frame.info.isIdleFrame
            )
        )
    }
}

#endif
