//
//  DesktopVirtualDisplayStartupAttempt.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/10/26.
//

import CoreGraphics
import MirageKit

#if os(macOS)
struct DesktopVirtualDisplayStartupAttempt: Equatable {
    let backingScale: DesktopBackingScaleResolution
    let refreshRate: Int
    let colorSpace: MirageColorSpace
    let label: String
    let isConservativeRetry: Bool
}

func desktopVirtualDisplayStartupAttempts(
    logicalResolution: CGSize,
    requestedScaleFactor: CGFloat,
    streamScale: CGFloat,
    disableResolutionCap: Bool,
    requestedRefreshRate: Int,
    requestedColorSpace: MirageColorSpace
) -> [DesktopVirtualDisplayStartupAttempt] {
    let primary = DesktopVirtualDisplayStartupAttempt(
        backingScale: resolvedDesktopBackingScaleResolution(
            logicalResolution: logicalResolution,
            defaultScaleFactor: requestedScaleFactor,
            streamScale: streamScale,
            disableResolutionCap: disableResolutionCap
        ),
        refreshRate: requestedRefreshRate,
        colorSpace: requestedColorSpace,
        label: "primary",
        isConservativeRetry: false
    )

    let conservative = DesktopVirtualDisplayStartupAttempt(
        backingScale: resolvedDesktopBackingScaleResolution(
            logicalResolution: logicalResolution,
            defaultScaleFactor: 1.0,
            streamScale: streamScale,
            disableResolutionCap: false
        ),
        refreshRate: SharedVirtualDisplayManager.streamRefreshRate(for: 60),
        colorSpace: .sRGB,
        label: "conservative-retry",
        isConservativeRetry: true
    )

    if primary.backingScale.pixelResolution == conservative.backingScale.pixelResolution,
       primary.refreshRate == conservative.refreshRate,
       primary.colorSpace == conservative.colorSpace {
        return [primary]
    }

    return [primary, conservative]
}
#endif
