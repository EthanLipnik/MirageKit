//
//  SharedVirtualDisplayManager+DisplayModeTypes.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/9/26.
//

import MirageKit
#if os(macOS)
import CoreGraphics

extension SharedVirtualDisplayManager {
    struct ObservedDisplayMode: Equatable {
        let logicalResolution: CGSize
        let pixelResolution: CGSize
        let refreshRate: Double
    }

    enum DisplayValidationOutcome: Equatable {
        case ready
        case screenCaptureKitVisibilityDelayed(CGDirectDisplayID)
        case modeMismatch
    }

    enum DisplayModeValidationAcceptance: Equatable {
        case strict
        case lenientOneX
        case missingCoreGraphicsRefreshOneX
        case missingCoreGraphicsMode

        var logLabel: String {
            switch self {
            case .strict:
                "strict"
            case .lenientOneX:
                "lenient 1x"
            case .missingCoreGraphicsRefreshOneX:
                "missing CoreGraphics refresh 1x"
            case .missingCoreGraphicsMode:
                "missing CoreGraphics mode/refresh"
            }
        }
    }

    struct DisplayModeValidationSnapshot: Equatable {
        let boundsSize: CGSize
        let screenCaptureSize: CGSize
        let modeLogicalSize: CGSize
        let modePixelSize: CGSize
        let modeRefreshRate: Double?
    }

    struct DisplayCreationAttempt: Equatable {
        let resolution: CGSize
        let hiDPI: Bool
        let colorSpace: MirageColorSpace
        let label: String
    }
}
#endif
