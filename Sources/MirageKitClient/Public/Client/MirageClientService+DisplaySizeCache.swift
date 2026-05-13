//
//  MirageClientService+DisplaySizeCache.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/12/26.
//

import CoreGraphics

#if os(iOS) || os(visionOS)
extension MirageClientService {
    /// Cached drawable size from the sample-buffer view.
    public static var lastKnownViewSize: CGSize = .zero
    /// Cached drawable pixel size from the sample-buffer view.
    public static var lastKnownDrawablePixelSize: CGSize = .zero
    /// Cached active screen bounds in points.
    public static var lastKnownScreenPointSize: CGSize = .zero
    /// Cached active screen scale factor.
    public static var lastKnownScreenScale: CGFloat = 0
    /// Cached active screen native pixel size.
    public static var lastKnownScreenNativePixelSize: CGSize = .zero
    /// Cached active screen native scale factor.
    public static var lastKnownScreenNativeScale: CGFloat = 0
}
#endif
