//
//  DisplayCaptureStartupReadiness.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/9/26.
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
#if os(macOS)

/// Quality of ScreenCaptureKit samples observed before measuring display capture startup.
enum DisplayCaptureStartupReadiness: String, Sendable, Equatable {
    /// At least one usable non-idle frame was observed.
    case usableFrameSeen

    /// Capture produced samples, but only idle frames were observed.
    case idleFrameSeen

    /// Capture produced only blank or suspended samples.
    case blankOrSuspendedOnly

    /// No ScreenCaptureKit samples arrived before the startup wait expired.
    case noScreenSamples
}

#endif
