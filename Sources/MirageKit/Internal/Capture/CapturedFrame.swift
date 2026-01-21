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
}

/// Captured frame with owned pixel buffer and timing metadata.
struct CapturedFrame: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let presentationTime: CMTime
    let duration: CMTime
    let info: CapturedFrameInfo
}

#endif
