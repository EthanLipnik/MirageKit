//
//  MirageStreamPresentationPolicy.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/8/26.
//

import CoreGraphics
import MirageKit

enum MirageStreamPresentationPolicy {
    static func keyboardOcclusionActive(
        softwareKeyboardVisible: Bool,
        localKeyboardOcclusionActive: Bool
    )
    -> Bool {
        softwareKeyboardVisible || localKeyboardOcclusionActive
    }

    static func keyboardAvoidancePresentationActive(
        keyboardAvoidanceEnabled: Bool,
        softwareKeyboardVisible: Bool,
        localKeyboardOcclusionActive: Bool
    )
    -> Bool {
        keyboardAvoidanceEnabled &&
            keyboardOcclusionActive(
                softwareKeyboardVisible: softwareKeyboardVisible,
                localKeyboardOcclusionActive: localKeyboardOcclusionActive
            )
    }

    static func suppressesDesktopResizeForLocalPresentation(
        isDesktopStream: Bool,
        useHostResolution: Bool,
        desktopCaptureSource: MirageDesktopCaptureSource,
        desktopStreamAllowsClientResize: Bool
    )
    -> Bool {
        isDesktopStream &&
            (useHostResolution || desktopCaptureSource == .mainDisplayFallback || !desktopStreamAllowsClientResize)
    }

    static func suppressesWindowDrivenResizeForLocalPresentation(
        isDesktopStream: Bool,
        useHostResolution: Bool,
        desktopCaptureSource: MirageDesktopCaptureSource,
        desktopStreamAllowsClientResize: Bool
    )
    -> Bool {
        suppressesDesktopResizeForLocalPresentation(
            isDesktopStream: isDesktopStream,
            useHostResolution: useHostResolution,
            desktopCaptureSource: desktopCaptureSource,
            desktopStreamAllowsClientResize: desktopStreamAllowsClientResize
        )
    }

    static func prefersLocalAspectFitPresentation(
        localPresentationPauseActive: Bool,
        isDesktopStream: Bool,
        useHostResolution: Bool,
        desktopCaptureSource: MirageDesktopCaptureSource,
        desktopStreamAllowsClientResize: Bool,
        keyboardAvoidanceEnabled: Bool,
        softwareKeyboardVisible: Bool,
        localKeyboardOcclusionActive: Bool,
        appStreamPrefersAspectFitPresentation: Bool
    )
    -> Bool {
        localPresentationPauseActive ||
            suppressesDesktopResizeForLocalPresentation(
                isDesktopStream: isDesktopStream,
                useHostResolution: useHostResolution,
                desktopCaptureSource: desktopCaptureSource,
                desktopStreamAllowsClientResize: desktopStreamAllowsClientResize
            ) ||
            keyboardAvoidancePresentationActive(
                keyboardAvoidanceEnabled: keyboardAvoidanceEnabled,
                softwareKeyboardVisible: softwareKeyboardVisible,
                localKeyboardOcclusionActive: localKeyboardOcclusionActive
            ) ||
            appStreamPrefersAspectFitPresentation
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
