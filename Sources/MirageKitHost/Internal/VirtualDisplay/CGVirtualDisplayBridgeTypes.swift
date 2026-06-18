//
//  CGVirtualDisplayBridgeTypes.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/9/26.
//

import CoreGraphics
import MirageKit

#if os(macOS)

extension CGVirtualDisplayBridge {
    struct VirtualDisplayContext {
        let display: AnyObject
        let displayID: CGDirectDisplayID
        let refreshRate: Double
        let colorSpace: MirageColorSpace
        let displayP3CoverageStatus: MirageDisplayP3CoverageStatus
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
