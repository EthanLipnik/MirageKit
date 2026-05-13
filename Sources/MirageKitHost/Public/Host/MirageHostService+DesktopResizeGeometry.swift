//
//  MirageHostService+DesktopResizeGeometry.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/9/26.
//

import CoreGraphics
import Foundation
import MirageKit

#if os(macOS)

@MainActor
extension MirageHostService {
    /// Whether a shared-display resize or mirroring transition is active.
    var desktopSharedDisplayTransitionInFlight: Bool {
        desktopSharedDisplayTransitionDepth > 0
    }

    /// Marks the beginning of a nested shared-display transition.
    func beginDesktopSharedDisplayTransition() {
        desktopSharedDisplayTransitionDepth += 1
    }

    /// Marks the end of a nested shared-display transition.
    func endDesktopSharedDisplayTransition() {
        desktopSharedDisplayTransitionDepth = max(0, desktopSharedDisplayTransitionDepth - 1)
    }

    /// Returns the desktop stream's current started pixel resolution.
    func currentDesktopStartedResolution(fallback: CGSize? = nil) async -> CGSize {
        await currentDesktopVirtualDisplayPixelResolution(fallback: fallback) ?? .zero
    }

    /// Converts a logical desktop resolution into even-aligned physical pixels.
    func virtualDisplayPixelResolution(
        for logicalResolution: CGSize,
        scaleFactorOverride: CGFloat? = nil
    )
    -> CGSize {
        guard logicalResolution.width > 0, logicalResolution.height > 0 else { return logicalResolution }
        let scale: CGFloat = if let scaleFactorOverride, scaleFactorOverride > 0 {
            max(1.0, scaleFactorOverride)
        } else {
            max(1.0, sharedVirtualDisplayScaleFactor)
        }
        let width = CGFloat(MirageStreamGeometry.alignedEncodedDimension(logicalResolution.width * scale))
        let height = CGFloat(MirageStreamGeometry.alignedEncodedDimension(logicalResolution.height * scale))
        return CGSize(width: width, height: height)
    }

    /// Resolves the display and encoded geometry for a desktop resize request.
    func resolvedDesktopResizeGeometry(
        request: DesktopResizeRequestState,
        context: StreamContext,
        preResizeSnapshot: SharedVirtualDisplayManager.DisplaySnapshot?
    )
    async -> DesktopResizeResolvedGeometry {
        let requestedDisplayScaleFactor = max(
            1.0,
            request.requestedDisplayScaleFactor ??
                desktopRequestedScaleFactor ??
                preResizeSnapshot?.scaleFactor ??
                sharedVirtualDisplayScaleFactor
        )
        let pixelResolution: CGSize = if desktopUsesHostResolution {
            if let resolution = preResizeSnapshot?.resolution {
                resolution
            } else {
                await currentDesktopStartedResolution()
            }
        } else {
            virtualDisplayPixelResolution(
                for: request.logicalResolution,
                scaleFactorOverride: requestedDisplayScaleFactor
            )
        }

        let requestedStreamScale: CGFloat = if let requestedStreamScale = request.requestedStreamScale {
            requestedStreamScale
        } else {
            await context.requestedStreamScale
        }
        let currentEncoderMax = await context.encoderMaxDimensions
        let encoderMaxWidth = request.encoderMaxWidth ?? currentEncoderMax.width
        let encoderMaxHeight = request.encoderMaxHeight ?? currentEncoderMax.height
        let disableResolutionCap = context.disableResolutionCap
        let encodedPlan = MirageStreamGeometry.resolveEncodedPlan(
            basePixelSize: pixelResolution,
            requestedStreamScale: requestedStreamScale,
            encoderMaxWidth: encoderMaxWidth ?? Int(StreamContext.maxEncodedWidth),
            encoderMaxHeight: encoderMaxHeight ?? Int(StreamContext.maxEncodedHeight),
            disableResolutionCap: disableResolutionCap
        )
        let targetFrameRate = await context.encoderConfig.targetFrameRate
        let refreshRate = SharedVirtualDisplayManager.streamRefreshRate(for: targetFrameRate)

        return DesktopResizeResolvedGeometry(
            logicalResolution: request.logicalResolution,
            pixelResolution: pixelResolution,
            encodedResolution: encodedPlan.encodedPixelSize,
            requestedDisplayScaleFactor: requestedDisplayScaleFactor,
            requestedStreamScale: requestedStreamScale,
            encoderMaxWidth: encoderMaxWidth,
            encoderMaxHeight: encoderMaxHeight,
            refreshRate: refreshRate
        )
    }
}

#endif
