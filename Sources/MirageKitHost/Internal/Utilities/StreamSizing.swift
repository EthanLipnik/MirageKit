//
//  StreamSizing.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/3/26.
//

import CoreGraphics
import MirageKit

#if os(macOS)
import AppKit

/// Encoded pixel dimensions and host scale used for a captured window stream.
struct StreamTargetDimensions {
    /// Width aligned to Mirage's encoder-safe pixel boundary.
    let width: Int
    /// Height aligned to Mirage's encoder-safe pixel boundary.
    let height: Int
    /// Backing scale used to convert the host window's point size to pixels.
    let hostScaleFactor: CGFloat
}

/// Returns encoder-aligned pixel dimensions for a host window at its detected screen scale.
///
/// Window streams default to native host pixel density. The explicit-scale overload is used when
/// callers already know the backing scale, such as virtual-display paths that cannot rely on `NSScreen`.
func streamTargetDimensions(windowFrame: CGRect) -> StreamTargetDimensions {
    let hostScaleFactor = screenScaleFactor(for: windowFrame)
    return streamTargetDimensions(windowFrame: windowFrame, scaleFactor: hostScaleFactor)
}

/// Returns encoder-aligned pixel dimensions for a host window with an explicit backing scale.
func streamTargetDimensions(windowFrame: CGRect, scaleFactor: CGFloat) -> StreamTargetDimensions {
    let encodedSize = MirageStreamGeometry.alignedEncodedSize(
        CGSize(width: windowFrame.width * scaleFactor, height: windowFrame.height * scaleFactor)
    )
    return StreamTargetDimensions(
        width: Int(encodedSize.width),
        height: Int(encodedSize.height),
        hostScaleFactor: scaleFactor
    )
}

private func screenScaleFactor(for frame: CGRect) -> CGFloat {
    let windowCenter = CGPoint(x: frame.midX, y: frame.midY)
    if let screen = NSScreen.screens.first(where: { $0.frame.contains(windowCenter) }) {
        return screen.backingScaleFactor
    }
    return NSScreen.main?.backingScaleFactor ?? 2.0
}
#endif
