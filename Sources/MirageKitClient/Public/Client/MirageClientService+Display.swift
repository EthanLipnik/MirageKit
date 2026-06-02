//
//  MirageClientService+Display.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Display resolution helpers and host notifications.
//

import CoreGraphics
import Foundation
import MirageKit

#if canImport(AppKit)
import AppKit
#endif

#if canImport(UIKit)
import UIKit
#endif

@MainActor
extension MirageClientService {
    /// Maximum encoded size Vision Pro clients should request from the host.
    public nonisolated static let visionOSMaximumEncodedPixelSize = CGSize(width: 3840, height: 2160)

    /// Vision Pro desktop streams should request a Retina-style virtual display
    /// even when UIKit has not yet reported a native window scale.
    public nonisolated static let visionOSPreferredVirtualDisplayScaleFactor: CGFloat = 2.0

    /// Total pixel count equivalent to 4K (3840 x 2160).
    private nonisolated static let fixedVisionOSPixelCount: CGFloat = 8_294_400

    /// Compute a display resolution that maintains a fixed 4K pixel budget
    /// while adapting the aspect ratio to the given view size and staying within
    /// the Vision Pro 4K encoded-size limit.
    /// Used on visionOS where resizing the window changes the aspect ratio
    /// rather than the resolution.
    public func visionOSFixedPixelCountResolution(for viewSize: CGSize) -> CGSize {
        Self.fixedPixelBudgetLogicalResolution(
            for: viewSize,
            displayScaleFactor: max(
                Self.visionOSPreferredVirtualDisplayScaleFactor,
                platformDisplayScaleFactor(explicitScaleFactor: nil)
            )
        )
    }

    private nonisolated static func fixedPixelBudgetLogicalResolution(
        for viewSize: CGSize,
        displayScaleFactor: CGFloat,
        pixelCount: CGFloat = fixedVisionOSPixelCount,
        maximumEncodedPixelSize: CGSize = visionOSMaximumEncodedPixelSize
    )
    -> CGSize {
        let displayScaleFactor = max(
            visionOSPreferredVirtualDisplayScaleFactor,
            MirageStreamGeometry.clampedDisplayScaleFactor(displayScaleFactor)
        )
        let fallbackPixelSize = CGSize(
            width: max(2, maximumEncodedPixelSize.width),
            height: max(2, maximumEncodedPixelSize.height)
        )
        guard viewSize.width > 0, viewSize.height > 0 else {
            return MirageStreamGeometry.normalizedLogicalSize(
                CGSize(
                    width: fallbackPixelSize.width / displayScaleFactor,
                    height: fallbackPixelSize.height / displayScaleFactor
                )
            )
        }
        let aspectRatio = viewSize.width / viewSize.height
        let budgetHeight = sqrt(max(1, pixelCount) / aspectRatio)
        let budgetWidth = budgetHeight * aspectRatio
        let widthScale = maximumEncodedPixelSize.width > 0
            ? maximumEncodedPixelSize.width / budgetWidth
            : 1.0
        let heightScale = maximumEncodedPixelSize.height > 0
            ? maximumEncodedPixelSize.height / budgetHeight
            : 1.0
        let encodedScale = min(1.0, widthScale, heightScale)
        return MirageStreamGeometry.normalizedLogicalSize(
            CGSize(
                width: (budgetWidth * encodedScale) / displayScaleFactor,
                height: (budgetHeight * encodedScale) / displayScaleFactor
            )
        )
    }

    /// Converts a logical display resolution into the pixel size requested for the virtual display.
    public func virtualDisplayPixelResolution(for displayResolution: CGSize) -> CGSize {
        let alignedResolution = MirageStreamGeometry.normalizedLogicalSize(displayResolution)
        guard alignedResolution.width > 0, alignedResolution.height > 0 else { return .zero }

        let requestedScale: CGFloat
        #if os(macOS)
        requestedScale = NSScreen.main?.backingScaleFactor ?? 2.0
        #elseif os(iOS) || os(visionOS)
        let metrics = resolvedScreenMetrics
        let nativePoints = MirageStreamGeometry.normalizedLogicalSize(metrics.nativePointSize)
        let nativePixels = MirageStreamGeometry.normalizedLogicalSize(metrics.nativePixelSize)
        if nativePoints.width > 0,
           nativePoints.height > 0,
           nativePixels.width > 0,
           nativePixels.height > 0 {
            let widthScale = nativePixels.width / nativePoints.width
            let heightScale = nativePixels.height / nativePoints.height
            requestedScale = max(widthScale, heightScale)
        } else if metrics.nativeScale > 0 {
            requestedScale = metrics.nativeScale
        } else {
            requestedScale = 1.0
        }
        #else
        requestedScale = 1.0
        #endif

        return MirageStreamGeometry.resolve(
            logicalSize: alignedResolution,
            displayScaleFactor: requestedScale
        ).displayPixelSize
    }

    func resolvedDisplayScaleFactor(
        for logicalResolution: CGSize,
        explicitScaleFactor: CGFloat?
    )
    -> CGFloat? {
        let alignedLogical = MirageStreamGeometry.normalizedLogicalSize(logicalResolution)
        guard alignedLogical.width > 0, alignedLogical.height > 0 else { return nil }
        let geometry = MirageStreamGeometry.resolve(
            logicalSize: alignedLogical,
            displayScaleFactor: platformDisplayScaleFactor(explicitScaleFactor: explicitScaleFactor)
        )
        guard geometry.displayScaleFactor > 0 else { return nil }
        return geometry.displayScaleFactor
    }

    func inferredDisplayScaleFactor(
        displayPixelSize: CGSize,
        presentationSize: CGSize
    ) -> CGFloat? {
        let presentationSize = MirageStreamGeometry.normalizedLogicalSize(presentationSize)
        guard displayPixelSize.width > 0,
              displayPixelSize.height > 0,
              presentationSize.width > 0,
              presentationSize.height > 0 else {
            return nil
        }
        let widthScale = displayPixelSize.width / presentationSize.width
        let heightScale = displayPixelSize.height / presentationSize.height
        let scale = max(widthScale, heightScale)
        guard scale.isFinite, scale > 0 else { return nil }
        return max(1.0, scale)
    }

    func acceptedDesktopDisplayScaleFactor(
        from started: DesktopStreamStartedMessage,
        displayPixelSize: CGSize,
        presentationSize: CGSize
    ) -> CGFloat? {
        if let acceptedScale = started.acceptedDisplayScaleFactor,
           acceptedScale.isFinite,
           acceptedScale > 0 {
            return max(1.0, acceptedScale)
        }

        if let lastSentTarget = desktopResizeCoordinator.lastSentTarget,
           lastSentTarget.displayPixelsMatchAccepted(displayPixelSize) {
            return lastSentTarget.displayScaleFactor
        }

        return inferredDisplayScaleFactor(
            displayPixelSize: displayPixelSize,
            presentationSize: presentationSize
        )
    }

    func preferredDesktopDisplayResolution(for viewSize: CGSize) -> CGSize {
        let alignedViewSize = MirageStreamGeometry.normalizedLogicalSize(viewSize)
        guard alignedViewSize.width > 0, alignedViewSize.height > 0 else { return .zero }

        #if os(iOS) || os(visionOS)
        let metrics = resolvedScreenMetrics
        let screenPoints = MirageStreamGeometry.normalizedLogicalSize(metrics.pointSize)
        let nativePoints = MirageStreamGeometry.normalizedLogicalSize(metrics.nativePointSize)
        if screenPoints.width > 0,
           screenPoints.height > 0,
           nativePoints.width > 0,
           nativePoints.height > 0,
           abs(alignedViewSize.width - screenPoints.width) <= max(8, screenPoints.width * 0.02),
           abs(alignedViewSize.height - screenPoints.height) <= max(8, screenPoints.height * 0.02) {
            return nativePoints
        }
        #endif

        return alignedViewSize
    }

    /// Main display size in logical points for the current client platform.
    public var mainDisplayResolution: CGSize {
        #if os(macOS)
        guard let mainScreen = NSScreen.main else { return CGSize(width: 2560, height: 1600) }
        return MirageStreamGeometry.normalizedLogicalSize(mainScreen.frame.size)
        #elseif os(iOS) || os(visionOS)
        let metrics = resolvedScreenMetrics
        let nativePoints = MirageStreamGeometry.normalizedLogicalSize(metrics.nativePointSize)
        if nativePoints.width > 0, nativePoints.height > 0 { return nativePoints }
        if Self.lastKnownViewSize.width > 0, Self.lastKnownViewSize.height > 0 {
            return MirageStreamGeometry.normalizedLogicalSize(Self.lastKnownViewSize)
        }
        return .zero
        #else
        return CGSize(width: 2560, height: 1600)
        #endif
    }

    /// Main display size in native pixels for the current client platform.
    public var mainDisplayNativePixelResolution: CGSize {
        #if os(macOS)
        guard let mainScreen = NSScreen.main else { return CGSize(width: 2560, height: 1600) }
        let scale = mainScreen.backingScaleFactor
        return MirageStreamGeometry.normalizedLogicalSize(
            CGSize(
                width: mainScreen.frame.width * scale,
                height: mainScreen.frame.height * scale
            )
        )
        #elseif os(iOS) || os(visionOS)
        let metrics = resolvedScreenMetrics
        let nativePixels = MirageStreamGeometry.normalizedLogicalSize(metrics.nativePixelSize)
        if nativePixels.width > 0, nativePixels.height > 0 { return nativePixels }

        let cachedNativePixels = MirageStreamGeometry.normalizedLogicalSize(Self.lastKnownScreenNativePixelSize)
        if cachedNativePixels.width > 0, cachedNativePixels.height > 0 {
            return cachedNativePixels
        }
        return .zero
        #else
        return CGSize(width: 2560, height: 1600)
        #endif
    }

    /// Pixel size requested for the virtual display that backs the main client display.
    public var virtualDisplayPixelResolution: CGSize {
        virtualDisplayPixelResolution(for: mainDisplayResolution)
    }

    func resolvedStreamGeometry(
        for logicalResolution: CGSize,
        explicitScaleFactor: CGFloat? = nil,
        requestedStreamScale: CGFloat? = nil,
        encoderMaxWidth: Int? = nil,
        encoderMaxHeight: Int? = nil,
        disableResolutionCap: Bool = false
    ) -> MirageStreamGeometry {
        let alignedLogicalResolution = MirageStreamGeometry.normalizedLogicalSize(logicalResolution)

        return MirageStreamGeometry.resolve(
            logicalSize: alignedLogicalResolution,
            displayScaleFactor: platformDisplayScaleFactor(explicitScaleFactor: explicitScaleFactor),
            requestedStreamScale: requestedStreamScale ?? MirageStreamGeometry.clampStreamScale(resolutionScale),
            encoderMaxWidth: encoderMaxWidth,
            encoderMaxHeight: encoderMaxHeight,
            disableResolutionCap: disableResolutionCap
        )
    }

    func platformDisplayScaleFactor(explicitScaleFactor: CGFloat?) -> CGFloat {
        if let explicitScaleFactor, explicitScaleFactor > 0 {
            return max(1.0, explicitScaleFactor)
        }

        #if os(macOS)
        return NSScreen.main?.backingScaleFactor ?? 2.0
        #elseif os(iOS) || os(visionOS)
        let metrics = resolvedScreenMetrics
        let nativePoints = MirageStreamGeometry.normalizedLogicalSize(metrics.nativePointSize)
        let nativePixels = MirageStreamGeometry.normalizedLogicalSize(metrics.nativePixelSize)
        if nativePoints.width > 0,
           nativePoints.height > 0,
           nativePixels.width > 0,
           nativePixels.height > 0 {
            let widthScale = nativePixels.width / nativePoints.width
            let heightScale = nativePixels.height / nativePoints.height
            return max(1.0, max(widthScale, heightScale))
        }
        if metrics.nativeScale > 0 { return max(1.0, metrics.nativeScale) }
        return 1.0
        #else
        return 1.0
        #endif
    }

    /// Send display size change (points) to host when the client view bounds change.
    public func sendDisplayResolutionChange(streamID: StreamID, newResolution: CGSize) async throws {
        guard case .connected = connectionState else { throw MirageError.protocolError("Not connected") }

        let scaledResolution = MirageStreamGeometry.normalizedLogicalSize(newResolution)

        let pixelResolution = virtualDisplayPixelResolution(for: scaledResolution)
        let request = DisplayResolutionChangeMessage(
            streamID: streamID,
            displayWidth: Int(scaledResolution.width),
            displayHeight: Int(scaledResolution.height)
        )
        MirageLogger
            .client(
                "Sending display size change for stream \(streamID): " +
                    "\(Int(scaledResolution.width))x\(Int(scaledResolution.height)) pts " +
                    "(\(Int(pixelResolution.width))x\(Int(pixelResolution.height)) px)"
            )

        try await sendControlMessage(.displayResolutionChange, content: request)
    }

    func sendDesktopResizeRequest(
        streamID: StreamID,
        newResolution: CGSize,
        transitionID: UUID,
        requestedDisplayScaleFactor: CGFloat,
        requestedStreamScale: CGFloat,
        encoderMaxWidth: Int?,
        encoderMaxHeight: Int?,
        desktopGeometryContractID: UUID?,
        desktopGeometrySceneIdentity: String?,
        desktopGeometryRefreshTargetHz: Int?
    )
    async throws {
        guard case .connected = connectionState else { throw MirageError.protocolError("Not connected") }

        let scaledResolution = MirageStreamGeometry.normalizedLogicalSize(newResolution)
        let clampedDisplayScaleFactor = max(1.0, requestedDisplayScaleFactor)
        let clampedStreamScale = MirageStreamGeometry.clampStreamScale(requestedStreamScale)
        let pixelResolution = MirageStreamGeometry.resolve(
            logicalSize: scaledResolution,
            displayScaleFactor: clampedDisplayScaleFactor
        ).displayPixelSize

        let request = DisplayResolutionChangeMessage(
            streamID: streamID,
            displayWidth: Int(scaledResolution.width),
            displayHeight: Int(scaledResolution.height),
            transitionID: transitionID,
            requestedDisplayScaleFactor: clampedDisplayScaleFactor,
            requestedStreamScale: clampedStreamScale,
            encoderMaxWidth: encoderMaxWidth,
            encoderMaxHeight: encoderMaxHeight,
            desktopGeometryContractID: desktopGeometryContractID,
            desktopGeometrySceneIdentity: desktopGeometrySceneIdentity,
            desktopGeometryRefreshTargetHz: desktopGeometryRefreshTargetHz
        )
        MirageLogger.client(
            "Sending desktop resize request for stream \(streamID): " +
                "\(Int(scaledResolution.width))x\(Int(scaledResolution.height)) pts " +
                "(\(Int(pixelResolution.width))x\(Int(pixelResolution.height)) px), " +
                "transition=\(transitionID.uuidString), " +
                "contract=\(desktopGeometryContractID?.uuidString ?? "nil"), " +
                "displayScale=\(String(format: "%.3f", clampedDisplayScaleFactor)), " +
                "streamScale=\(String(format: "%.3f", clampedStreamScale))"
        )
        try await sendControlMessage(.displayResolutionChange, content: request)
    }

    /// Sends a stream-scale change for an active stream.
    public func sendStreamScaleChange(
        streamID: StreamID,
        scale: CGFloat
    )
    async throws {
        guard case .connected = connectionState else { throw MirageError.protocolError("Not connected") }

        let clampedScale = MirageStreamGeometry.clampStreamScale(scale)
        let request = StreamScaleChangeMessage(
            streamID: streamID,
            streamScale: clampedScale
        )
        MirageLogger.client("Sending stream scale change for stream \(streamID): \(clampedScale)")
        try await sendControlMessage(.streamScaleChange, content: request)
    }

}
