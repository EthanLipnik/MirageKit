//
//  MirageStreamPresentationPolicy.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/8/26.
//

import CoreGraphics
import MirageKit

enum MirageStreamPresentationPolicy {
    static func suppressesWindowDrivenResizeForLocalPresentation(
        isDesktopStream: Bool,
        useHostResolution: Bool,
        desktopCaptureSource: MirageDesktopCaptureSource,
        desktopStreamAllowsClientResize: Bool,
        keyboardAvoidanceEnabled: Bool,
        softwareKeyboardVisible: Bool,
        localKeyboardOcclusionActive: Bool
    )
    -> Bool {
        let suppressesDesktopResize = isDesktopStream &&
            (useHostResolution || desktopCaptureSource == .mainDisplayFallback || !desktopStreamAllowsClientResize)
        let suppressesForKeyboard = keyboardAvoidanceEnabled &&
            (softwareKeyboardVisible || localKeyboardOcclusionActive)
        return suppressesDesktopResize || suppressesForKeyboard
    }

    static func localAspectFitReferenceSize(
        prefersLocalAspectFitPresentation: Bool,
        hostDisplayPointSize: CGSize?
    )
    -> CGSize? {
        guard prefersLocalAspectFitPresentation else { return nil }
        guard let hostDisplayPointSize,
              hostDisplayPointSize.width > 0,
              hostDisplayPointSize.height > 0 else {
            return nil
        }
        return hostDisplayPointSize
    }

    static func containerSize(
        boundsSize: CGSize,
        contentLayoutSize: CGSize?,
        mode: MirageStreamContainerSizingMode
    )
    -> CGSize {
        switch mode {
        case .contentLayout:
            if let contentLayoutSize,
               contentLayoutSize.width > 0,
               contentLayoutSize.height > 0 {
                return contentLayoutSize
            }
            return boundsSize
        case .viewBounds:
            return boundsSize
        }
    }
}
