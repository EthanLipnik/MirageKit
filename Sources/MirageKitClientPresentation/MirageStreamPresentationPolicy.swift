//
//  MirageStreamPresentationPolicy.swift
//  MirageKitClientPresentation
//
//  Created by Ethan Lipnik on 6/5/26.
//

import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageKit
import MirageMedia
import MirageWire
import CoreGraphics

/// Bounds source used by client presentation sizing policy.
package enum MiragePresentationContainerSizingMode: Sendable, Equatable {
    case contentLayout
    case viewBounds
}

/// Local client sizing policy for stream presentation containers.
package enum MirageStreamPresentationPolicy {
    package static func keyboardOcclusionActive(
        softwareKeyboardVisible: Bool,
        localKeyboardOcclusionActive: Bool
    )
    -> Bool {
        softwareKeyboardVisible || localKeyboardOcclusionActive
    }

    package static func keyboardAvoidancePresentationActive(
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

    package static func suppressesDesktopResizeForLocalPresentation(
        isDesktopStream: Bool,
        useHostResolution: Bool,
        desktopCaptureSource: MirageWire.MirageDesktopCaptureSource,
        desktopStreamAllowsClientResize: Bool
    )
    -> Bool {
        isDesktopStream &&
            (useHostResolution || desktopCaptureSource == .mainDisplayFallback || !desktopStreamAllowsClientResize)
    }

    package static func suppressesWindowDrivenResizeForLocalPresentation(
        isDesktopStream: Bool,
        useHostResolution: Bool,
        desktopCaptureSource: MirageWire.MirageDesktopCaptureSource,
        desktopStreamAllowsClientResize: Bool,
        keyboardAvoidanceEnabled: Bool,
        softwareKeyboardVisible: Bool,
        localKeyboardOcclusionActive: Bool
    )
    -> Bool {
        if keyboardAvoidancePresentationActive(
            keyboardAvoidanceEnabled: keyboardAvoidanceEnabled,
            softwareKeyboardVisible: softwareKeyboardVisible,
            localKeyboardOcclusionActive: localKeyboardOcclusionActive
        ) {
            return true
        }

        return suppressesDesktopResizeForLocalPresentation(
            isDesktopStream: isDesktopStream,
            useHostResolution: useHostResolution,
            desktopCaptureSource: desktopCaptureSource,
            desktopStreamAllowsClientResize: desktopStreamAllowsClientResize
        )
    }

    package static func prefersLocalAspectFitPresentation() -> Bool {
        true
    }

    package static func localAspectFitReferenceSize(
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

    package static func containerSize(
        boundsSize: CGSize,
        contentLayoutSize: CGSize?,
        mode: MiragePresentationContainerSizingMode
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
