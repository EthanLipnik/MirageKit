//
//  SCKWrappers.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/5/26.
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
import Foundation
#if os(macOS)
import CoreGraphics
import ScreenCaptureKit

/// Wrapper to send SCWindow across actor boundaries safely
/// SCWindow is a ScreenCaptureKit type that's internally thread-safe
struct SCWindowWrapper: @unchecked Sendable {
    let window: SCWindow
}

/// Wrapper to send SCRunningApplication across actor boundaries safely
struct SCApplicationWrapper: @unchecked Sendable {
    let application: SCRunningApplication
}

/// Wrapper to send SCDisplay across actor boundaries safely
struct SCDisplayWrapper: @unchecked Sendable {
    let display: SCDisplay
}

/// Wrapper to send SCShareableContent across actor boundaries safely.
struct SCShareableContentWrapper: @unchecked Sendable {
    let content: SCShareableContent

    func displayWrapper(for displayID: CGDirectDisplayID) -> SCDisplayWrapper? {
        content.displays
            .first { $0.displayID == displayID }
            .map(SCDisplayWrapper.init(display:))
    }

    var displayIDs: [CGDirectDisplayID] {
        content.displays.map(\.displayID)
    }
}

#endif
