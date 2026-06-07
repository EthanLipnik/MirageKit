//
//  StreamContext+SharedDisplayAppLayout.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/9/26.
//
//  Shared-display app-stream layout helpers.
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
import Foundation

#if os(macOS)
import ScreenCaptureKit

extension StreamContext {
    struct SharedDisplayAppPresentationLayout: Equatable {
        let primaryRect: CGRect
        let clusterRect: CGRect
        let presentationRect: CGRect
        let destinationRect: CGRect
    }

    struct SharedDisplayAppCaptureLayout {
        let primaryWindowWrapper: SCWindowWrapper
        let includedWindowWrappers: [SCWindowWrapper]
        let clusterWindowIDs: [WindowID]
        let primaryRect: CGRect
        let clusterRect: CGRect
        let presentationRect: CGRect
        let captureSourceRect: CGRect
        let destinationRect: CGRect
    }

    /// Resolves the ScreenCaptureKit window cluster and capture rectangles for shared-display app streaming.
    func resolveSharedDisplayAppCaptureLayout(
        primaryWindowID: WindowID,
        primaryWindowWrapper fallbackPrimaryWindowWrapper: SCWindowWrapper? = nil,
        primaryWindowFrameOverride: CGRect? = nil,
        displayWrapper: SCDisplayWrapper,
        outputSize: CGSize,
        label: String
    ) async throws -> SharedDisplayAppCaptureLayout {
        let primaryWindowWrapper = if let fallbackPrimaryWindowWrapper {
            fallbackPrimaryWindowWrapper
        } else {
            try await resolveSCWindowWrapper(windowID: primaryWindowID, label: label)
        }

        let normalizedBundleIdentifier = appStreamBundleIdentifier?.lowercased() ??
            primaryWindowWrapper.window.owningApplication?.bundleIdentifier.lowercased()
        var clusterWindowIDs = [primaryWindowID]
        if let normalizedBundleIdentifier {
            do {
                let candidates = try await AppStreamWindowCatalog.catalog(
                    for: [normalizedBundleIdentifier],
                    captureContentProviderBackend: captureContentProviderBackend
                )[normalizedBundleIdentifier]
                if let candidates,
                   let cluster = AppStreamWindowCatalog.capturedWindowCluster(
                       primaryWindowID: primaryWindowID,
                       candidates: candidates
                   ) {
                    clusterWindowIDs = cluster.windowIDs
                }
            } catch {
                MirageLogger.error(.host, error: error, message: "Failed to resolve shared-display app window cluster: ")
            }
        }

        let content = try await currentCaptureShareableContent()
        let windowsByID = Dictionary(uniqueKeysWithValues: content.windows.map { (WindowID($0.windowID), $0) })
        let includedWindowWrappers = clusterWindowIDs.compactMap { windowID in
            windowsByID[windowID].map { SCWindowWrapper(window: $0) }
        }
        let resolvedIncludedWindowWrappers = includedWindowWrappers.isEmpty ? [primaryWindowWrapper] : includedWindowWrappers
        let resolvedClusterWindowIDs = resolvedIncludedWindowWrappers.map { WindowID($0.window.windowID) }
        let displayBounds = displayWrapper.display.frame.standardized
        let resolvedPrimaryWindowFrame: CGRect = if let primaryWindowFrameOverride, !primaryWindowFrameOverride.isEmpty {
            primaryWindowFrameOverride.standardized
        } else {
            primaryWindowWrapper.window.frame.standardized
        }
        let primaryDisplayRect = resolvedPrimaryWindowFrame
            .standardized
            .intersection(displayBounds)
            .standardized
        let sourceUnionRect = resolvedIncludedWindowWrappers
            .map { wrapper in
                let wrapperWindowID = WindowID(wrapper.window.windowID)
                if wrapperWindowID == primaryWindowID,
                   let primaryWindowFrameOverride,
                   !primaryWindowFrameOverride.isEmpty {
                    return primaryWindowFrameOverride.standardized
                }
                return wrapper.window.frame.standardized
            }
            .reduce(CGRect.null) { partialResult, rect in
                partialResult.isNull ? rect : partialResult.union(rect)
            }
        let clusterDisplayRect = sourceUnionRect
            .intersection(displayBounds)
            .standardized
        let presentationLayout = Self.sharedDisplayAppPresentationLayout(
            primaryRect: primaryDisplayRect,
            clusterRect: clusterDisplayRect,
            outputSize: outputSize
        )
        let captureSourceRect = Self.sharedDisplayAppCaptureSourceRect(
            presentationRect: presentationLayout.presentationRect,
            displayBounds: displayBounds
        )

        return SharedDisplayAppCaptureLayout(
            primaryWindowWrapper: primaryWindowWrapper,
            includedWindowWrappers: resolvedIncludedWindowWrappers,
            clusterWindowIDs: resolvedClusterWindowIDs,
            primaryRect: presentationLayout.primaryRect,
            clusterRect: presentationLayout.clusterRect,
            presentationRect: presentationLayout.presentationRect,
            captureSourceRect: captureSourceRect,
            destinationRect: presentationLayout.destinationRect
        )
    }

    /// Re-resolves and applies the shared-display app capture layout to the running capture engine.
    func refreshSharedDisplayAppCaptureLayout(
        primaryWindowWrapper: SCWindowWrapper? = nil,
        primaryWindowFrameOverride: CGRect? = nil,
        label: String
    ) async throws {
        guard isRunning,
              isAppStream,
              useVirtualDisplay,
              captureMode == .display,
              let captureEngine,
              let virtualDisplayContext else {
            return
        }

        let displayWrapper = try await resolveSCDisplayWrapper(
            displayID: virtualDisplayContext.displayID,
            label: "\(label) mirrored app capture display"
        )
        let layout = try await resolveSharedDisplayAppCaptureLayout(
            primaryWindowID: windowID,
            primaryWindowWrapper: primaryWindowWrapper,
            primaryWindowFrameOverride: primaryWindowFrameOverride,
            displayWrapper: displayWrapper,
            outputSize: currentEncodedSize,
            label: label
        )
        let displayBounds = displayWrapper.display.frame.standardized
        let visibleBounds = virtualDisplayBackend.displayVisibleBounds(
            displayWrapper.display.displayID,
            knownBounds: displayBounds
        )
        let resolvedVisibleBounds = visibleBounds.isEmpty
            ? displayBounds
            : visibleBounds.intersection(displayBounds)

        lastWindowFrame = if let primaryWindowFrameOverride, !primaryWindowFrameOverride.isEmpty {
            primaryWindowFrameOverride.standardized
        } else {
            layout.primaryWindowWrapper.window.frame.standardized
        }
        capturedWindowClusterWindowIDs = layout.clusterWindowIDs
        virtualDisplayVisibleBounds = resolvedVisibleBounds
        virtualDisplayCapturePresentationRect = layout.presentationRect
        virtualDisplayCaptureSourceRect = layout.captureSourceRect
        currentContentRect = layout.destinationRect

        try await captureEngine.updateDisplayCaptureLayout(
            display: displayWrapper.display,
            sourceRect: layout.captureSourceRect,
            destinationRect: layout.destinationRect,
            contentWindowID: windowID,
            includedWindows: layout.includedWindowWrappers.map(\.window)
        )
        await refreshCaptureCadence()

        MirageLogger.stream(
            "Updated shared-display app capture layout for stream \(streamID): " +
                "primary=\(windowID), cluster=\(layout.clusterWindowIDs), primaryRect=\(layout.primaryRect), " +
                "clusterRect=\(layout.clusterRect), presentationRect=\(layout.presentationRect), " +
                "destinationRect=\(layout.destinationRect)"
        )
    }

    private static let sharedDisplayAppAutoWidenTolerance: CGFloat = 8

    nonisolated static func mirroredAppWindowPlacementBounds(
        sourceVisibleBounds: CGRect,
        mirroredVisibleBounds: CGRect
    )
    -> CGRect {
        let normalizedMirroredBounds = mirroredVisibleBounds.standardized
        if normalizedMirroredBounds.width > 0, normalizedMirroredBounds.height > 0 {
            return normalizedMirroredBounds
        }
        let normalizedSourceBounds = sourceVisibleBounds.standardized
        if normalizedSourceBounds.width > 0, normalizedSourceBounds.height > 0 {
            return normalizedSourceBounds
        }
        return normalizedMirroredBounds
    }

    nonisolated static func targetWindowAspectRatio(
        requestedLogicalSize: CGSize,
        sizePreset: MirageMedia.MirageDisplaySizePreset
    ) -> CGFloat {
        let presetAspectRatio = sizePreset.contentAspectRatio
        guard presetAspectRatio.isFinite, presetAspectRatio > 0 else {
            let requestedAspectRatio = requestedLogicalSize.width > 0 && requestedLogicalSize.height > 0
                ? requestedLogicalSize.width / requestedLogicalSize.height
                : 1
            return requestedAspectRatio.isFinite && requestedAspectRatio > 0 ? requestedAspectRatio : 1
        }
        return presetAspectRatio
    }

    nonisolated static func aspectFittedFrame(
        within bounds: CGRect,
        aspectRatio: CGFloat?
    ) -> CGRect {
        let normalizedBounds = bounds.standardized
        guard let aspectRatio,
              aspectRatio.isFinite,
              aspectRatio > 0,
              normalizedBounds.width > 0,
              normalizedBounds.height > 0 else {
            return normalizedBounds
        }

        let boundsAspectRatio = normalizedBounds.width / normalizedBounds.height
        guard abs(boundsAspectRatio - aspectRatio) > 0.0001 else { return normalizedBounds }

        var fittedWidth = normalizedBounds.width
        var fittedHeight = normalizedBounds.height

        if boundsAspectRatio > aspectRatio {
            fittedWidth = floor(normalizedBounds.height * aspectRatio)
        } else {
            fittedHeight = floor(normalizedBounds.width / aspectRatio)
        }

        fittedWidth = max(1, fittedWidth)
        fittedHeight = max(1, fittedHeight)

        return CGRect(
            x: normalizedBounds.minX + floor((normalizedBounds.width - fittedWidth) * 0.5),
            y: normalizedBounds.minY + floor((normalizedBounds.height - fittedHeight) * 0.5),
            width: fittedWidth,
            height: fittedHeight
        )
    }

    nonisolated static func fixedCanvasDestinationRect(
        sourceRect: CGRect,
        outputSize: CGSize
    ) -> CGRect {
        guard sourceRect.width > 0,
              sourceRect.height > 0,
              outputSize.width > 0,
              outputSize.height > 0 else {
            return CGRect(origin: .zero, size: outputSize)
        }

        let scale = min(outputSize.width / sourceRect.width, outputSize.height / sourceRect.height)
        let fittedSize = CGSize(
            width: max(1, floor(sourceRect.width * scale)),
            height: max(1, floor(sourceRect.height * scale))
        )
        return CGRect(
            x: floor((outputSize.width - fittedSize.width) * 0.5),
            y: floor((outputSize.height - fittedSize.height) * 0.5),
            width: fittedSize.width,
            height: fittedSize.height
        )
    }

    nonisolated static func sharedDisplayAppCaptureSourceRect(
        presentationRect: CGRect,
        displayBounds: CGRect
    ) -> CGRect {
        let resolvedDisplayBounds = displayBounds.standardized
        guard resolvedDisplayBounds.width > 0,
              resolvedDisplayBounds.height > 0 else {
            return .zero
        }

        let resolvedPresentationRect = presentationRect
            .standardized
            .intersection(resolvedDisplayBounds)
            .standardized
        guard resolvedPresentationRect.width > 0,
              resolvedPresentationRect.height > 0 else {
            return .zero
        }

        return CGRect(
            x: max(0, resolvedPresentationRect.minX - resolvedDisplayBounds.minX),
            y: max(0, resolvedPresentationRect.minY - resolvedDisplayBounds.minY),
            width: resolvedPresentationRect.width,
            height: resolvedPresentationRect.height
        )
    }

    nonisolated static func sharedDisplayAppShouldAutoWiden(
        primaryRect: CGRect,
        clusterRect: CGRect,
        tolerance: CGFloat = sharedDisplayAppAutoWidenTolerance
    ) -> Bool {
        guard primaryRect.width > 0,
              primaryRect.height > 0,
              clusterRect.width > 0,
              clusterRect.height > 0 else {
            return false
        }

        return clusterRect.minX < (primaryRect.minX - tolerance) ||
            clusterRect.minY < (primaryRect.minY - tolerance) ||
            clusterRect.maxX > (primaryRect.maxX + tolerance) ||
            clusterRect.maxY > (primaryRect.maxY + tolerance)
    }

    nonisolated static func sharedDisplayAppPresentationLayout(
        primaryRect: CGRect,
        clusterRect: CGRect,
        outputSize: CGSize,
        autoWidenTolerance: CGFloat = sharedDisplayAppAutoWidenTolerance
    ) -> SharedDisplayAppPresentationLayout {
        let normalizedPrimaryRect = primaryRect.standardized
        let normalizedClusterRect = clusterRect.standardized

        let resolvedPrimaryRect: CGRect = if normalizedPrimaryRect.width > 0, normalizedPrimaryRect.height > 0 {
            normalizedPrimaryRect
        } else {
            normalizedClusterRect
        }

        let resolvedClusterRect: CGRect = if normalizedClusterRect.width > 0, normalizedClusterRect.height > 0 {
            normalizedClusterRect
        } else {
            resolvedPrimaryRect
        }

        let presentationRect = sharedDisplayAppShouldAutoWiden(
            primaryRect: resolvedPrimaryRect,
            clusterRect: resolvedClusterRect,
            tolerance: autoWidenTolerance
        ) ? resolvedClusterRect : resolvedPrimaryRect
        let destinationRect = fixedCanvasDestinationRect(
            sourceRect: presentationRect,
            outputSize: outputSize
        )

        return SharedDisplayAppPresentationLayout(
            primaryRect: resolvedPrimaryRect,
            clusterRect: resolvedClusterRect,
            presentationRect: presentationRect,
            destinationRect: destinationRect
        )
    }
}
#endif
