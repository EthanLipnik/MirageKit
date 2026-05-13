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

    enum P3D65Primaries {
        static let red = CGPoint(x: 0.680, y: 0.320)
        static let green = CGPoint(x: 0.265, y: 0.690)
        static let blue = CGPoint(x: 0.150, y: 0.060)
        static let whitePoint = CGPoint(x: 0.3127, y: 0.3290)
    }

    enum SRGBPrimaries {
        static let red = CGPoint(x: 0.640, y: 0.330)
        static let green = CGPoint(x: 0.300, y: 0.600)
        static let blue = CGPoint(x: 0.150, y: 0.060)
        static let whitePoint = CGPoint(x: 0.3127, y: 0.3290)
    }
}

#endif
