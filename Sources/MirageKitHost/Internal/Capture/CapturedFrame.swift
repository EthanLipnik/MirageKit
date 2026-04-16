//
//  CapturedFrame.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/21/26.
//

import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import MirageKit

#if os(macOS)

/// Frame information passed from capture to encoding.
struct CapturedFrameInfo: Sendable {
    /// The pixel buffer content area (excluding black padding).
    let contentRect: CGRect
    /// Total area of dirty regions as percentage of frame (0-100).
    let dirtyPercentage: Float
    /// True when SCK reports the frame as idle (no changes).
    let isIdleFrame: Bool
}

/// Captured frame with timing metadata and optional sample-buffer ownership.
struct CapturedFrame: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let presentationTime: CMTime
    let duration: CMTime
    /// Host wall time when the frame was received from SCK (used for pacing).
    let captureTime: CFAbsoluteTime
    let info: CapturedFrameInfo
    /// Retains the originating sample buffer for zero-copy ScreenCaptureKit frames.
    let backingSampleBuffer: CMSampleBuffer?

    init(
        pixelBuffer: CVPixelBuffer,
        presentationTime: CMTime,
        duration: CMTime,
        captureTime: CFAbsoluteTime,
        info: CapturedFrameInfo,
        backingSampleBuffer: CMSampleBuffer? = nil
    ) {
        self.pixelBuffer = pixelBuffer
        self.presentationTime = presentationTime
        self.duration = duration
        self.captureTime = captureTime
        self.info = info
        self.backingSampleBuffer = backingSampleBuffer
    }
}

/// Captured audio buffer copied from ScreenCaptureKit output.
struct CapturedAudioBuffer: Sendable {
    /// Raw PCM bytes in stream order.
    let data: Data
    /// Source sample rate in Hz.
    let sampleRate: Double
    /// Source channel count.
    let channelCount: Int
    /// Number of PCM frames (per channel) in `data`.
    let frameCount: Int
    /// Bytes per PCM frame.
    let bytesPerFrame: Int
    /// Bits per PCM channel.
    let bitsPerChannel: Int
    /// Whether source samples are floating point.
    let isFloat: Bool
    /// Whether source layout is interleaved.
    let isInterleaved: Bool
    /// Host presentation timestamp for sync.
    let presentationTime: CMTime
}

#endif
