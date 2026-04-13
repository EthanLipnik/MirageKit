//
//  StreamContext+Streaming+VirtualDisplay.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Display capture on a shared virtual display.
//

import Foundation
import MirageKit

#if os(macOS)
import ScreenCaptureKit

extension StreamContext {
    struct SharedDisplayAppPresentationLayout: Sendable, Equatable {
        let primaryRect: CGRect
        let clusterRect: CGRect
        let presentationRect: CGRect
        let destinationRect: CGRect
        let contentRect: CGRect
    }

    struct WindowCaptureDisplaySelection: Equatable {
        let captureDisplayID: CGDirectDisplayID
        let usesDisplayRefreshCadence: Bool
    }

    struct SharedDisplayAppCaptureLayout: Sendable {
        let primaryWindowWrapper: SCWindowWrapper
        let includedWindowWrappers: [SCWindowWrapper]
        let clusterWindowIDs: [WindowID]
        let primaryRect: CGRect
        let clusterRect: CGRect
        let presentationRect: CGRect
        let captureSourceRect: CGRect
        let destinationRect: CGRect

        var sourceRect: CGRect { captureSourceRect }
        var contentRect: CGRect { destinationRect }
    }

    private static let sharedDisplayAppAutoWidenTolerance: CGFloat = 8

    nonisolated static func windowCaptureDisplaySelection(
        sourceDisplayID: CGDirectDisplayID,
        mirroredDisplayID: CGDirectDisplayID?,
        captureDisplayIsMirage: Bool
    )
    -> WindowCaptureDisplaySelection {
        let captureDisplayID = mirroredDisplayID ?? sourceDisplayID
        return WindowCaptureDisplaySelection(
            captureDisplayID: captureDisplayID,
            usesDisplayRefreshCadence: mirroredDisplayID != nil || captureDisplayIsMirage
        )
    }

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
        sizePreset: MirageDisplaySizePreset
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

        let resolvedPrimaryRect: CGRect
        if normalizedPrimaryRect.width > 0, normalizedPrimaryRect.height > 0 {
            resolvedPrimaryRect = normalizedPrimaryRect
        } else {
            resolvedPrimaryRect = normalizedClusterRect
        }

        let resolvedClusterRect: CGRect
        if normalizedClusterRect.width > 0, normalizedClusterRect.height > 0 {
            resolvedClusterRect = normalizedClusterRect
        } else {
            resolvedClusterRect = resolvedPrimaryRect
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
            destinationRect: destinationRect,
            contentRect: destinationRect
        )
    }

    private func resolveSharedDisplayAppCaptureLayout(
        primaryWindowID: WindowID,
        primaryWindowWrapper fallbackPrimaryWindowWrapper: SCWindowWrapper? = nil,
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
        if let normalizedBundleIdentifier,
           let candidates = try? await AppStreamWindowCatalog.catalog(for: [normalizedBundleIdentifier])[normalizedBundleIdentifier],
           let cluster = AppStreamWindowCatalog.capturedWindowCluster(
               primaryWindowID: primaryWindowID,
               candidates: candidates
           ) {
            clusterWindowIDs = cluster.windowIDs
        }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let windowsByID = Dictionary(uniqueKeysWithValues: content.windows.map { (WindowID($0.windowID), $0) })
        let includedWindowWrappers = clusterWindowIDs.compactMap { windowID in
            windowsByID[windowID].map { SCWindowWrapper(window: $0) }
        }
        let resolvedIncludedWindowWrappers = includedWindowWrappers.isEmpty ? [primaryWindowWrapper] : includedWindowWrappers
        let resolvedClusterWindowIDs = resolvedIncludedWindowWrappers.map { WindowID($0.window.windowID) }
        let displayBounds = displayWrapper.display.frame.standardized
        let primaryDisplayRect = primaryWindowWrapper.window.frame
            .standardized
            .intersection(displayBounds)
            .standardized
        let sourceUnionRect = resolvedIncludedWindowWrappers
            .map { $0.window.frame.standardized }
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

    func refreshSharedDisplayAppCaptureLayout(
        primaryWindowWrapper: SCWindowWrapper? = nil,
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
            displayWrapper: displayWrapper,
            outputSize: currentEncodedSize,
            label: label
        )
        let displayBounds = displayWrapper.display.frame.standardized
        let visibleBounds = CGVirtualDisplayBridge.getDisplayVisibleBounds(
            displayWrapper.display.displayID,
            knownBounds: displayBounds
        )
        let resolvedVisibleBounds = visibleBounds.isEmpty
            ? displayBounds
            : visibleBounds.intersection(displayBounds)

        lastWindowFrame = layout.primaryWindowWrapper.window.frame
        capturedWindowClusterWindowIDs = layout.clusterWindowIDs
        virtualDisplayVisibleBounds = resolvedVisibleBounds
        virtualDisplayCapturePresentationRect = layout.presentationRect
        virtualDisplayCaptureSourceRect = layout.captureSourceRect
        let scaleFactor = max(1.0, virtualDisplayContext.scaleFactor)
        virtualDisplayVisiblePixelResolution = CGSize(
            width: max(1, ceil(resolvedVisibleBounds.width * scaleFactor)),
            height: max(1, ceil(resolvedVisibleBounds.height * scaleFactor))
        )
        currentContentRect = layout.contentRect

        try await captureEngine.updateDisplayCaptureLayout(
            display: displayWrapper.display,
            sourceRect: layout.sourceRect,
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

    func updateWindowCaptureVirtualDisplayState(_ snapshot: SharedVirtualDisplayManager.DisplaySnapshot?) {
        guard let snapshot else {
            virtualDisplayVisibleBounds = .zero
            virtualDisplayCaptureSourceRect = .zero
            virtualDisplayCapturePresentationRect = .zero
            virtualDisplayVisiblePixelResolution = .zero
            return
        }

        let scaleFactor = max(1.0, snapshot.scaleFactor)
        let logicalResolution = SharedVirtualDisplayManager.logicalResolution(
            for: snapshot.resolution,
            scaleFactor: scaleFactor
        )
        var displayBounds = CGVirtualDisplayBridge.getDisplayBounds(
            snapshot.displayID,
            knownResolution: logicalResolution
        )
        if displayBounds.isEmpty {
            displayBounds = CGRect(origin: .zero, size: logicalResolution)
        }
        var visibleBounds = CGVirtualDisplayBridge.getDisplayVisibleBounds(
            snapshot.displayID,
            knownBounds: displayBounds
        )
        visibleBounds = visibleBounds.intersection(displayBounds)
        if visibleBounds.isEmpty {
            visibleBounds = displayBounds
        }

        virtualDisplayVisibleBounds = visibleBounds
        let captureSourceRect = CGVirtualDisplayBridge.displayCaptureSourceRect(
            snapshot.displayID,
            knownBounds: displayBounds
        )
        virtualDisplayCapturePresentationRect = visibleBounds
        virtualDisplayCaptureSourceRect = captureSourceRect.isEmpty
            ? CGRect(origin: .zero, size: displayBounds.size)
            : captureSourceRect
        virtualDisplayVisiblePixelResolution = CGSize(
            width: max(1, ceil(visibleBounds.width * scaleFactor)),
            height: max(1, ceil(visibleBounds.height * scaleFactor))
        )
    }

    func resolveWindowCaptureDisplayWrapper(
        sourceDisplayWrapper: SCDisplayWrapper,
        mirroredDisplaySnapshot: SharedVirtualDisplayManager.DisplaySnapshot?,
        label: String
    )
    async throws -> SCDisplayWrapper {
        guard let mirroredDisplaySnapshot else { return sourceDisplayWrapper }
        if mirroredDisplaySnapshot.displayID == sourceDisplayWrapper.display.displayID {
            return sourceDisplayWrapper
        }
        return try await resolveSCDisplayWrapper(
            displayID: mirroredDisplaySnapshot.displayID,
            label: label
        )
    }

    /// Starts shared-display capture for an app-stream virtual display.
    ///
    /// Mirrored app streaming normalizes the host window onto the shared app-stream display,
    /// then captures that display with a display filter limited to the selected window cluster.
    func startSharedDisplayWindowCapture(
        windowWrapper: SCWindowWrapper,
        applicationWrapper: SCApplicationWrapper,
        displayWrapper: SCDisplayWrapper,
        mirroredDisplaySnapshot: SharedVirtualDisplayManager.DisplaySnapshot,
        sizePreset: MirageDisplaySizePreset,
        clientLogicalSize: CGSize,
        sendPacket: @escaping @Sendable (Data, @escaping @Sendable (Error?) -> Void) -> Void,
        onSendError: (@Sendable (Error) -> Void)? = nil
    )
    async throws {
        guard !isRunning else { return }
        isRunning = true
        useVirtualDisplay = true
        captureFrameRateOverride = currentFrameRate
        captureFrameRate = currentFrameRate

        let application = applicationWrapper.application
        isAppStream = true
        applicationProcessID = application.processID
        appStreamBundleIdentifier = application.bundleIdentifier.lowercased()
        trafficLightMaskGeometryCache = nil
        lastTrafficLightMaskLogTime = 0

        await setupPacketSender(sendPacket: sendPacket, onSendError: onSendError)

        virtualDisplayContext = mirroredDisplaySnapshot
        updateWindowCaptureVirtualDisplayState(mirroredDisplaySnapshot)

        MirageLogger.stream(
            "Stream \(streamID) using shared app-stream display \(mirroredDisplaySnapshot.displayID) " +
            "(\(Int(mirroredDisplaySnapshot.resolution.width))x\(Int(mirroredDisplaySnapshot.resolution.height)) @\(mirroredDisplaySnapshot.scaleFactor)x)"
        )

        let scaleFactor = max(1.0, mirroredDisplaySnapshot.scaleFactor)
        let logicalResolution = SharedVirtualDisplayManager.logicalResolution(
            for: mirroredDisplaySnapshot.resolution,
            scaleFactor: scaleFactor
        )
        let mirroredDisplayBounds = CGVirtualDisplayBridge.getDisplayBounds(
            mirroredDisplaySnapshot.displayID,
            knownResolution: logicalResolution
        )
        let mirroredVisibleBounds = CGVirtualDisplayBridge.getDisplayVisibleBounds(
            mirroredDisplaySnapshot.displayID,
            knownBounds: mirroredDisplayBounds
        )
        let effectiveMirroredVisibleBounds = mirroredVisibleBounds.isEmpty
            ? mirroredDisplayBounds
            : mirroredVisibleBounds.intersection(mirroredDisplayBounds)
        let sourceDisplayBounds = CGDisplayBounds(displayWrapper.display.displayID)
        let sourceVisibleBounds = CGVirtualDisplayBridge.getDisplayVisibleBounds(
            displayWrapper.display.displayID,
            knownBounds: sourceDisplayBounds
        )
        let effectiveSourceVisibleBounds = sourceVisibleBounds.isEmpty
            ? sourceDisplayBounds
            : sourceVisibleBounds.intersection(sourceDisplayBounds)
        let placementBounds = Self.mirroredAppWindowPlacementBounds(
            sourceVisibleBounds: effectiveSourceVisibleBounds,
            mirroredVisibleBounds: effectiveMirroredVisibleBounds
        )
        let targetContentAspectRatio = Self.targetWindowAspectRatio(
            requestedLogicalSize: clientLogicalSize,
            sizePreset: sizePreset
        )
        let targetWindowFrame = Self.aspectFittedFrame(
            within: placementBounds,
            aspectRatio: targetContentAspectRatio
        )
        virtualDisplayVisibleBounds = placementBounds
        virtualDisplayCapturePresentationRect = targetWindowFrame
        virtualDisplayCaptureSourceRect = Self.sharedDisplayAppCaptureSourceRect(
            presentationRect: targetWindowFrame,
            displayBounds: mirroredDisplayBounds
        )
        virtualDisplayVisiblePixelResolution = CGSize(
            width: max(1, ceil(placementBounds.width * scaleFactor)),
            height: max(1, ceil(placementBounds.height * scaleFactor))
        )
        let targetWindowSize = targetWindowFrame.size
        MirageLogger.stream(
            "Stream \(streamID) window target: \(Int(targetWindowSize.width))x\(Int(targetWindowSize.height)) " +
            "(client requested \(Int(clientLogicalSize.width))x\(Int(clientLogicalSize.height)), " +
            "placement visible \(Int(placementBounds.width))x\(Int(placementBounds.height)), " +
            "preset=\(sizePreset.displayName))"
        )

        _ = try await resolveSCWindowWrapper(
            windowID: windowID,
            label: "pre-prepare window capture"
        )
        let resolvedDisplayWrapper = try await resolveWindowCaptureDisplayWrapper(
            sourceDisplayWrapper: displayWrapper,
            mirroredDisplaySnapshot: mirroredDisplaySnapshot,
            label: "mirrored app capture display"
        )

        try await WindowSpaceManager.shared.prepareWindowForMirroredCapture(
            windowID,
            owner: WindowSpaceManager.WindowBindingOwner(
                streamID: streamID,
                windowID: windowID,
                displayID: mirroredDisplaySnapshot.displayID,
                generation: mirroredDisplaySnapshot.generation
            )
        )

        await iterativelyResizeWindow(
            windowID: windowID,
            targetSize: targetWindowSize,
            aspectRatio: targetContentAspectRatio,
            maxBounds: placementBounds.size,
            label: "startup"
        )
        await WindowSpaceManager.shared.centerWindow(windowID, on: placementBounds)
        try? await Task.sleep(for: .milliseconds(60))

        let settledWindowWrapper = try await resolveSCWindowWrapper(
            windowID: windowID,
            label: "post-prepare window capture"
        )

        let captureTarget = streamTargetDimensions(windowFrame: settledWindowWrapper.window.frame)
        baseCaptureSize = CGSize(width: captureTarget.width, height: captureTarget.height)
        streamScale = resolvedStreamScale(
            for: baseCaptureSize,
            requestedScale: requestedStreamScale,
            logLabel: "Resolution cap"
        )
        let outputSize = scaledOutputSize(for: baseCaptureSize)
        currentCaptureSize = outputSize
        currentEncodedSize = outputSize
        captureMode = .display
        updateQueueLimits()
        await applyDerivedQuality(for: outputSize, logLabel: "Shared-display app capture init")
        MirageLogger.stream(
            "Shared-display app capture init: latency=\(latencyMode.displayName), scale=\(streamScale), " +
                "encoded=\(Int(outputSize.width))x\(Int(outputSize.height)), queue=\(maxQueuedBytes / 1024)KB"
        )

        let captureLayout = try await resolveSharedDisplayAppCaptureLayout(
            primaryWindowID: windowID,
            primaryWindowWrapper: settledWindowWrapper,
            displayWrapper: resolvedDisplayWrapper,
            outputSize: outputSize,
            label: "shared-display app capture start"
        )
        lastWindowFrame = captureLayout.primaryWindowWrapper.window.frame
        capturedWindowClusterWindowIDs = captureLayout.clusterWindowIDs
        virtualDisplayCapturePresentationRect = captureLayout.presentationRect
        virtualDisplayCaptureSourceRect = captureLayout.captureSourceRect
        currentContentRect = captureLayout.contentRect

        try await createAndPreheatEncoder(
            streamKind: .window,
            width: Int(outputSize.width),
            height: Int(outputSize.height)
        )
        await startEncoderWithSharedCallback(pinnedContentRect: nil, logPrefix: "Frame")

        let captureDisplaySelection = Self.windowCaptureDisplaySelection(
            sourceDisplayID: resolvedDisplayWrapper.display.displayID,
            mirroredDisplayID: mirroredDisplaySnapshot.displayID,
            captureDisplayIsMirage: CGVirtualDisplayBridge.isMirageDisplay(mirroredDisplaySnapshot.displayID)
        )
        let captureEngine = try await setupAndStartCaptureEngine(
            usesDisplayRefreshCadence: captureDisplaySelection.usesDisplayRefreshCadence
        )
        try await captureEngine.startDisplayCapture(
            display: resolvedDisplayWrapper.display,
            resolution: outputSize,
            sourceRect: captureLayout.sourceRect,
            destinationRect: captureLayout.destinationRect,
            contentWindowID: windowID,
            includedWindows: captureLayout.includedWindowWrappers.map(\.window),
            showsCursor: false,
            onFrame: { [weak self] frame in
                self?.enqueueCapturedFrame(frame)
            },
            onAudio: onCapturedAudioBuffer,
            audioChannelCount: requestedAudioChannelCount
        )
        await refreshCaptureCadence()

        MirageLogger.stream(
            "Started stream \(streamID) with shared-display app capture on display \(mirroredDisplaySnapshot.displayID) for window \(windowID) cluster=\(captureLayout.clusterWindowIDs)"
        )
    }

    /// Updates window size for a resolution change (no virtual display reconfiguration needed).
    func updateWindowCaptureResolution(
        newLogicalSize: CGSize,
        forceReconfigure: Bool = false
    ) async throws {
        guard isRunning, useVirtualDisplay else { return }
        let rollbackSnapshot = makeResizeRollbackSnapshot()

        let placementBounds = resolvedVirtualDisplayPlacementBounds(for: newLogicalSize)
        let maxBounds = placementBounds.size
        let requestedAspectRatio = newLogicalSize.width > 0 && newLogicalSize.height > 0
            ? newLogicalSize.width / newLogicalSize.height
            : nil
        let effectiveSize = Self.aspectFittedFrame(
            within: placementBounds,
            aspectRatio: requestedAspectRatio
        ).size

        let currentSize = lastWindowFrame.size
        let sizeChanged = abs(currentSize.width - effectiveSize.width) > 2 ||
            abs(currentSize.height - effectiveSize.height) > 2
        guard sizeChanged || forceReconfigure else {
            MirageLogger.stream(
                "Skipping window resize for stream \(streamID): size unchanged"
            )
            return
        }
        if forceReconfigure {
            MirageLogger.stream(
                "Preserving fixed-canvas app capture during resize for stream \(streamID); ignoring encoder reconfigure request"
            )
        }

        isResizing = true
        defer { isResizing = false }

        let previousWindowFrame = rollbackSnapshot.lastWindowFrame

        MirageLogger.stream(
            "Resizing window for stream \(streamID) to \(Int(effectiveSize.width))x\(Int(effectiveSize.height)) logical " +
            "(client requested \(Int(newLogicalSize.width))x\(Int(newLogicalSize.height)))"
        )

        // Iteratively resize the window to match target aspect ratio
        await iterativelyResizeWindow(
            windowID: windowID,
            targetSize: effectiveSize,
            aspectRatio: requestedAspectRatio,
            maxBounds: maxBounds,
            label: "resize"
        )
        await WindowSpaceManager.shared.centerWindow(windowID, on: placementBounds)

        // Brief pause for the window to settle
        try? await Task.sleep(for: .milliseconds(80))

        // Re-resolve the SCWindow and display for new capture
        let resolvedWindowWrapper = try await resolveSCWindowWrapper(
            windowID: windowID,
            label: "window resize"
        )
        let windowFrame = resolvedWindowWrapper.window.frame
        do {
            let captureTarget = streamTargetDimensions(windowFrame: windowFrame)
            baseCaptureSize = CGSize(width: captureTarget.width, height: captureTarget.height)
            lastWindowFrame = windowFrame
            currentCaptureSize = currentEncodedSize
            updateQueueLimits()
            try await refreshSharedDisplayAppCaptureLayout(
                primaryWindowWrapper: resolvedWindowWrapper,
                label: "window resize"
            )
            await applyDerivedQuality(for: currentEncodedSize, logLabel: "Shared-display app resize fixed canvas")
            MirageLogger.stream(
                "Window resize updated shared-display crop for stream \(streamID) without changing encoded canvas \(Int(currentEncodedSize.width))x\(Int(currentEncodedSize.height))"
            )
        } catch {
            var restoredWindowFrame = previousWindowFrame
            if !previousWindowFrame.isEmpty {
                let previousAspectRatio = previousWindowFrame.width > 0 && previousWindowFrame.height > 0
                    ? previousWindowFrame.width / previousWindowFrame.height
                    : nil
                await iterativelyResizeWindow(
                    windowID: windowID,
                    targetSize: previousWindowFrame.size,
                    aspectRatio: previousAspectRatio,
                    maxBounds: maxBounds,
                    label: "rollback"
                )
                await WindowSpaceManager.shared.centerWindow(windowID, on: placementBounds)
                try? await Task.sleep(for: .milliseconds(80))
                if let resolvedRollbackWindowWrapper = try? await resolveSCWindowWrapper(
                    windowID: windowID,
                    label: "window resize rollback"
                ) {
                    restoredWindowFrame = resolvedRollbackWindowWrapper.window.frame
                }
            }
            do {
                try await rollbackResizeFailure(
                    rollbackSnapshot,
                    logLabel: "Window resize",
                    restoredWindowFrame: restoredWindowFrame
                )
            } catch {
                MirageLogger.error(.stream, error: error, message: "Window resize rollback failed: ")
            }
            throw error
        }
    }

    // MARK: - SCK Resolution Helpers

    // MARK: - Aspect-Fit Sizing

    private func resolvedVirtualDisplayPlacementBounds(for fallbackLogicalSize: CGSize) -> CGRect {
        if let virtualDisplayContext {
            let scale = max(1.0, virtualDisplayContext.scaleFactor)
            let logicalResolution = SharedVirtualDisplayManager.logicalResolution(
                for: virtualDisplayContext.resolution,
                scaleFactor: scale
            )
            let displayBounds = CGVirtualDisplayBridge.getDisplayBounds(
                virtualDisplayContext.displayID,
                knownResolution: logicalResolution
            )
            let visibleBounds = CGVirtualDisplayBridge.getDisplayVisibleBounds(
                virtualDisplayContext.displayID,
                knownBounds: displayBounds
            )
            let resolvedVisibleBounds = visibleBounds.isEmpty
                ? displayBounds
                : visibleBounds.intersection(displayBounds)
            if resolvedVisibleBounds.width > 0, resolvedVisibleBounds.height > 0 {
                return resolvedVisibleBounds
            }
        }

        if virtualDisplayVisibleBounds.width > 0, virtualDisplayVisibleBounds.height > 0 {
            return virtualDisplayVisibleBounds
        }

        return CGRect(origin: .zero, size: fallbackLogicalSize)
    }

    /// Iteratively resize the window to match the target aspect ratio.
    /// Starts at `targetSize` and shrinks proportionally if the app rejects the size.
    /// Gives up after a few attempts — the window will be whatever the app accepted.
    func iterativelyResizeWindow(
        windowID: WindowID,
        targetSize: CGSize,
        aspectRatio: CGFloat?,
        maxBounds: CGSize,
        label: String
    ) async {
        let ar = aspectRatio ?? (targetSize.width / max(1, targetSize.height))
        var candidateW = targetSize.width
        var candidateH = targetSize.height
        let maxAttempts = 4

        for attempt in 1 ... maxAttempts {
            let candidate = CGSize(
                width: max(200, candidateW.rounded(.down)),
                height: max(200, candidateH.rounded(.down))
            )
            await WindowSpaceManager.shared.resizeWindow(windowID, to: candidate)

            // Brief settle
            try? await Task.sleep(for: .milliseconds(30))

            // Check actual compositor size via CGWindowList
            let windowFrame = Self.queryWindowFrame(windowID)
            if let windowFrame {
                let actualW = windowFrame.width
                let actualH = windowFrame.height
                let actualAR = actualW / max(1, actualH)
                let arDelta = abs(actualAR - ar) / max(0.001, ar)

                if arDelta < 0.03 {
                    // Close enough — aspect ratio matches within 3%
                    MirageLogger.stream(
                        "Window \(windowID) accepted \(Int(actualW))x\(Int(actualH)) at attempt \(attempt) " +
                        "(target AR \(String(format: "%.3f", ar)), actual AR \(String(format: "%.3f", actualAR)), \(label))"
                    )
                    return
                }

                // App rejected our size — it may have a minimum constraint.
                // Shrink the limiting dimension while preserving aspect ratio.
                if attempt < maxAttempts {
                    // Use the app's actual height (which is the constrained axis) and compute width from AR
                    if actualH < candidate.height {
                        // Height was constrained — use it and compute width
                        candidateH = actualH
                        candidateW = min(maxBounds.width, actualH * ar)
                    } else if actualW < candidate.width {
                        // Width was constrained — use it and compute height
                        candidateW = actualW
                        candidateH = min(maxBounds.height, actualW / ar)
                    } else {
                        // Both accepted but AR doesn't match — scale down uniformly
                        candidateW *= 0.92
                        candidateH *= 0.92
                    }
                    MirageLogger.stream(
                        "Window \(windowID) AR mismatch at \(Int(actualW))x\(Int(actualH)) " +
                        "(target AR \(String(format: "%.3f", ar)), actual \(String(format: "%.3f", actualAR))), " +
                        "retrying \(Int(candidateW))x\(Int(candidateH)) (\(label), attempt \(attempt + 1))"
                    )
                }
            } else {
                return // Can't query window, bail
            }
        }
    }

    /// Query a window's frame via CGWindowList.
    private static func queryWindowFrame(_ windowID: WindowID) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(windowID)) as? [[String: Any]],
              let info = list.first,
              let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat] else {
            return nil
        }
        return CGRect(
            x: boundsDict["X"] ?? 0,
            y: boundsDict["Y"] ?? 0,
            width: boundsDict["Width"] ?? 0,
            height: boundsDict["Height"] ?? 0
        )
    }

    // MARK: - SCK Resolution Helpers

    private func resolveSCWindowWrapper(
        windowID: WindowID,
        label: String,
        maxAttempts: Int = 10,
        initialDelayMs: Int = 100
    )
    async throws -> SCWindowWrapper {
        let attempts = max(1, maxAttempts)
        var delayMs = max(40, initialDelayMs)

        for attempt in 1 ... attempts {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            if let window = content.windows.first(where: { $0.windowID == CGWindowID(windowID) }) {
                if attempt > 1 {
                    MirageLogger.stream("Resolved SCWindow \(windowID) on attempt \(attempt) (\(label))")
                }
                return SCWindowWrapper(window: window)
            }
            if attempt < attempts {
                try? await Task.sleep(for: .milliseconds(Int64(delayMs)))
                delayMs = min(600, Int(Double(delayMs) * 1.5))
            } else {
                let windowDetails = content.windows.map { w in
                    "(\(w.windowID), \(w.owningApplication?.bundleIdentifier ?? "unknown"))"
                }
                MirageLogger.stream(
                    "Unable to resolve SCWindow \(windowID) after \(attempts) attempts (\(label)). " +
                    "Available windows (\(content.windows.count)): \(windowDetails)"
                )
            }
        }
        throw MirageError.protocolError("Unable to resolve SCWindow \(windowID) for stream \(streamID) (\(label))")
    }

    private func resolveSCDisplayWrapper(
        displayID: CGDirectDisplayID,
        label: String,
        maxAttempts: Int = 12,
        initialDelayMs: Int = 80
    )
    async throws -> SCDisplayWrapper {
        let attempts = max(1, maxAttempts)
        var delayMs = max(40, initialDelayMs)

        for attempt in 1 ... attempts {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            if let display = content.displays.first(where: { $0.displayID == displayID }) {
                if attempt > 1 {
                    MirageLogger.stream("Resolved SCDisplay \(displayID) on attempt \(attempt) (\(label))")
                }
                return SCDisplayWrapper(display: display)
            }
            if attempt < attempts {
                try? await Task.sleep(for: .milliseconds(Int64(delayMs)))
                delayMs = min(1000, Int(Double(delayMs) * 1.6))
            } else {
                let isOnline = CGDisplayIsOnline(displayID) != 0
                let available = content.displays.map(\.displayID)
                MirageLogger.stream(
                    "Unable to resolve SCDisplay \(displayID) after \(attempts) attempts (\(label)). " +
                    "CGDisplayIsOnline=\(isOnline), available SCK displays: \(available)"
                )
            }
        }
        throw MirageError.protocolError("Unable to resolve SCDisplay \(displayID) for stream \(streamID) (\(label))")
    }
}

#endif
