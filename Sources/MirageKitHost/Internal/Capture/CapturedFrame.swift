//
//  CapturedFrame.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/21/26.
//

import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageKit
import MirageKitClientPresentation
import MirageMedia
import MirageWire
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation

#if os(macOS)

/// Frame information passed from capture to encoding.
struct CapturedFrameInfo: Sendable {
    /// The pixel buffer content area (excluding black padding).
    let contentRect: CGRect
    /// Total area of dirty regions as percentage of frame (0-100).
    let dirtyPercentage: Float
    /// True when SCK reports the frame as idle (no changes).
    let isIdleFrame: Bool
    /// True for host-created frames used to drive recovery or still-quality probes.
    let isSynthetic: Bool

    init(
        contentRect: CGRect,
        dirtyPercentage: Float,
        isIdleFrame: Bool,
        isSynthetic: Bool = false
    ) {
        self.contentRect = contentRect
        self.dirtyPercentage = dirtyPercentage
        self.isIdleFrame = isIdleFrame
        self.isSynthetic = isSynthetic
    }
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
    /// Bits per PCM channel.
    let bitsPerChannel: Int
    /// Whether source samples are floating point.
    let isFloat: Bool
    /// Whether source layout is interleaved.
    let isInterleaved: Bool
    /// Host presentation timestamp for sync.
    let presentationTime: CMTime

    /// Duration represented by the captured PCM payload.
    var durationSeconds: Double {
        guard sampleRate > 0, frameCount > 0 else { return 0.010 }
        return Double(frameCount) / sampleRate
    }

    /// Estimates peak absolute sample amplitude from a bounded prefix of the payload.
    func estimatedPeakAmplitude(sampleLimit: Int = 4_096) -> Float {
        let bytesPerSample = max(1, bitsPerChannel / 8)
        let sampleCount = min(max(0, sampleLimit), data.count / bytesPerSample)
        guard sampleCount > 0 else { return 0 }

        return data.withUnsafeBytes { rawBuffer in
            var peak: Float = 0
            for sampleIndex in 0 ..< sampleCount {
                let offset = sampleIndex * bytesPerSample
                let amplitude = estimatedAmplitude(rawBuffer: rawBuffer, offset: offset)
                peak = max(peak, amplitude)
            }
            return min(1, peak)
        }
    }

    private func estimatedAmplitude(rawBuffer: UnsafeRawBufferPointer, offset: Int) -> Float {
        guard offset >= 0, offset < rawBuffer.count else { return 0 }
        if isFloat {
            if bitsPerChannel <= 32, offset + MemoryLayout<Float32>.size <= rawBuffer.count {
                let sample = rawBuffer.loadUnaligned(fromByteOffset: offset, as: Float32.self)
                return sample.isFinite ? abs(sample) : 0
            }
            if offset + MemoryLayout<Float64>.size <= rawBuffer.count {
                let sample = rawBuffer.loadUnaligned(fromByteOffset: offset, as: Float64.self)
                return sample.isFinite ? Float(abs(sample)) : 0
            }
            return 0
        }

        if bitsPerChannel <= 16, offset + MemoryLayout<Int16>.size <= rawBuffer.count {
            let sample = rawBuffer.loadUnaligned(fromByteOffset: offset, as: Int16.self)
            return Float(abs(Int(sample))) / Float(Int16.max)
        }

        if offset + MemoryLayout<Int32>.size <= rawBuffer.count {
            let sample = rawBuffer.loadUnaligned(fromByteOffset: offset, as: Int32.self)
            return Float(abs(Int64(sample))) / Float(Int32.max)
        }
        return 0
    }
}

#endif
