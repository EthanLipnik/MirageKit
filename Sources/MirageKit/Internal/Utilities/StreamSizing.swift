//
//  StreamSizing.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/3/26.
//

import CoreGraphics

#if os(macOS)
import AppKit

struct StreamTargetDimensions {
    let width: Int
    let height: Int
    let hostScaleFactor: CGFloat
}

/// Calculate host window dimensions at native resolution - no downscaling
/// This ensures maximum quality by always encoding at the host's native pixel density
func streamTargetDimensions(windowFrame: CGRect) -> StreamTargetDimensions {
    let hostScaleFactor = screenScaleFactor(for: windowFrame)
    return streamTargetDimensions(windowFrame: windowFrame, scaleFactor: hostScaleFactor)
}

/// Calculate host window dimensions with explicit scale factor
/// Use this when scale factor is known (e.g., virtual displays on headless Macs where NSScreen detection fails)
func streamTargetDimensions(windowFrame: CGRect, scaleFactor: CGFloat) -> StreamTargetDimensions {
    return StreamTargetDimensions(
        width: alignedEvenPixel(windowFrame.width * scaleFactor),
        height: alignedEvenPixel(windowFrame.height * scaleFactor),
        hostScaleFactor: scaleFactor
    )
}

/// Constrain a size to fit within a frame while preserving aspect ratio.
/// Returns the largest size that fits within the frame with the same aspect ratio as the input.
/// - Parameters:
///   - size: The size to constrain
///   - frame: The bounding frame to fit within
/// - Returns: Constrained size with preserved aspect ratio
func constrainSizeToFrame(_ size: CGSize, frame: CGRect) -> CGSize {
    guard size.width > 0 && size.height > 0 else { return size }

    let aspectRatio = size.width / size.height
    var width = size.width
    var height = size.height

    // If width exceeds frame, scale down proportionally
    if width > frame.width {
        width = frame.width
        height = width / aspectRatio
    }

    // If height still exceeds frame, scale down proportionally
    if height > frame.height {
        height = frame.height
        width = height * aspectRatio
    }

    return CGSize(width: width, height: height)
}

/// Calculate optimal host window size from relative scale and aspect ratio
/// - Parameters:
///   - aspectRatio: Desired width/height ratio (e.g., 1.333 for 4:3)
///   - relativeScale: Desired area as percentage of visibleFrame (0.0-1.0)
///   - visibleFrame: Host screen's visible area (excludes dock/menubar)
///   - minSize: Minimum window dimensions
/// - Returns: Optimal window size in points, always respecting aspect ratio
func calculateHostWindowSize(
    aspectRatio: CGFloat,
    relativeScale: CGFloat,
    visibleFrame: CGRect,
    minSize: CGSize = CGSize(width: 400, height: 300)
) -> CGSize {
    // Calculate target area based on visible screen area
    let screenArea = visibleFrame.width * visibleFrame.height
    let targetArea = screenArea * relativeScale

    // Solve for dimensions given area and aspect ratio:
    // area = width * height
    // aspectRatio = width / height
    // Therefore: width = sqrt(area * aspectRatio), height = sqrt(area / aspectRatio)
    var width = sqrt(targetArea * aspectRatio)
    var height = sqrt(targetArea / aspectRatio)

    // Enforce minimum size while maintaining aspect ratio
    if width < minSize.width {
        width = minSize.width
        height = width / aspectRatio
    }
    if height < minSize.height {
        height = minSize.height
        width = height * aspectRatio
    }

    // Final constraint to visibleFrame - always preserves aspect ratio
    return constrainSizeToFrame(CGSize(width: width, height: height), frame: visibleFrame)
}

/// Calculate host window size in points to produce exact pixel dimensions
/// This ensures 1:1 pixel matching between host capture and client drawable
/// - Parameters:
///   - targetPixels: The exact pixel dimensions the client needs
///   - windowFrame: Current window frame (to determine which screen/scale factor to use)
/// - Returns: Window size in points that will capture at targetPixels resolution
func hostWindowSizeForPixels(_ targetPixels: CGSize, windowFrame: CGRect) -> CGSize {
    let hostScale = screenScaleFactor(for: windowFrame)
    return CGSize(
        width: targetPixels.width / hostScale,
        height: targetPixels.height / hostScale
    )
}

// MARK: - Desktop Streaming Resolution

/// Maximum resolution for desktop streaming (5K)
private let maxDesktopStreamWidth: CGFloat = 5120
private let maxDesktopStreamHeight: CGFloat = 2880

/// Cap the requested resolution at 5K while maintaining aspect ratio
/// - Parameter requestedResolution: The resolution the client requested
/// - Returns: Resolution capped at 5K with preserved aspect ratio, with even dimensions
func capDesktopStreamResolution(_ requestedResolution: CGSize) -> CGSize {
    guard requestedResolution.width > 0 && requestedResolution.height > 0 else {
        // Fallback to default if invalid input
        return CGSize(width: 2880, height: 1800)
    }

    var width = requestedResolution.width
    var height = requestedResolution.height
    let aspectRatio = width / height

    // Cap at 5K while maintaining aspect ratio
    if width > maxDesktopStreamWidth {
        width = maxDesktopStreamWidth
        height = width / aspectRatio
    }

    if height > maxDesktopStreamHeight {
        height = maxDesktopStreamHeight
        width = height * aspectRatio
    }

    // Ensure dimensions are even (required for video encoding)
    let finalWidth = alignedEvenPixel(width)
    let finalHeight = alignedEvenPixel(height)

    return CGSize(width: CGFloat(finalWidth), height: CGFloat(finalHeight))
}

private func alignedEvenPixel(_ value: CGFloat) -> Int {
    let rounded = Int(value.rounded())
    let even = rounded - (rounded % 2)
    return max(even, 2)
}

private func screenScaleFactor(for frame: CGRect) -> CGFloat {
    let windowCenter = CGPoint(x: frame.midX, y: frame.midY)
    if let screen = NSScreen.screens.first(where: { $0.frame.contains(windowCenter) }) {
        return screen.backingScaleFactor
    }
    return NSScreen.main?.backingScaleFactor ?? 2.0
}
#endif
