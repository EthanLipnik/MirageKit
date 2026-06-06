//
//  MirageDiagnostics.MirageHostCaptureBenchmarkReport.swift
//  MirageKitHost
//
//  Created by Ethan Lipnik on 6/5/26.
//

@_spi(HostApp) import MirageDiagnostics

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

extension MirageDiagnostics.MirageHostCaptureBenchmarkStartupReadiness {
    init(_ readiness: DisplayCaptureStartupReadiness) {
        switch readiness {
        case .usableFrameSeen:
            self = .usableFrameSeen
        case .idleFrameSeen:
            self = .idleFrameSeen
        case .blankOrSuspendedOnly:
            self = .blankOrSuspendedOnly
        case .noScreenSamples:
            self = .noScreenSamples
        }
    }
}
#endif
