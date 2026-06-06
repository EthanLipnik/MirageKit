//
//  CGVirtualDisplayBridgeTypes.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/9/26.
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
import CoreGraphics

#if os(macOS)

extension CGVirtualDisplayBridge {
    struct VirtualDisplayContext {
        let display: AnyObject
        let displayID: CGDirectDisplayID
        let refreshRate: Double
        let colorSpace: MirageMedia.MirageColorSpace
        let displayP3CoverageStatus: MirageMedia.MirageDisplayP3CoverageStatus
    }

    struct VirtualDisplayCreationResult {
        let context: VirtualDisplayContext?
        let modeActivationResult: VirtualDisplayModeActivationResult?

        var failedBecauseRetinaCollapsedToOneX: Bool {
            modeActivationResult == .retinaCollapsedToOneX
        }
    }

    enum VirtualDisplayModeActivationResult: Equatable {
        case succeeded
        case failed
        case retinaCollapsedToOneX

        var succeeded: Bool {
            self == .succeeded
        }

        var isUsableForCreation: Bool {
            self == .succeeded || self == .retinaCollapsedToOneX
        }
    }
}

#endif
