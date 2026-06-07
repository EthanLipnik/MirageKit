//
//  MirageHostInputController+Resize.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Host input controller extensions.
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
import AppKit
import ApplicationServices

extension MirageHostInputController {
    // MARK: - Resize Handling

    /// Applies an absolute host-window resize from a client resize event.
    @MainActor
    func handleWindowResize(_ window: MirageMedia.MirageWindow, resizeEvent: MirageInput.MirageResizeEvent) {
        guard let windowController else { return }
        if hostService?.isStreamUsingVirtualDisplay(windowID: window.id) == true {
            MirageLogger.host(
                "Ignoring absolute resize for window \(window.id) using dedicated virtual display"
            )
            return
        }
        guard let axWindow = windowController.cachedAXWindow(for: window) else { return }

        let settable = windowController.isWindowSizeSettable(axWindow)
        let minSize = windowController.minimumSize(for: window.id)

        var newSize = resizeEvent.newSize
        if let minSize {
            newSize = CGSize(
                width: max(newSize.width, minSize.width),
                height: max(newSize.height, minSize.height)
            )
        }

        if let maxSize = windowController.maxWindowSize(for: window) {
            newSize.width = min(newSize.width, maxSize.width)
            newSize.height = min(newSize.height, maxSize.height)
        }

        if settable == false {
            if let actualFrame = windowController.axWindowFrame(axWindow) ?? windowController
                .currentWindowFrame(for: window.id) {
                windowController.updateMinimumSizeCache(for: window.id, size: actualFrame.size)
                notifyWindowResized(window, with: actualFrame)
            }
            return
        }

        var mutableSize = newSize
        guard let newSizeValue = AXValueCreate(.cgSize, &mutableSize) else { return }

        let setResult = AXUIElementSetAttributeValue(axWindow, kAXSizeAttribute as CFString, newSizeValue)

        if setResult == .success {
            windowController.requestFrameEnforcement(for: window, targetSize: newSize)
            let updatedFrame = windowController.axWindowFrame(axWindow)
                ?? windowController.currentWindowFrame(for: window.id)
                ?? CGRect(origin: window.frame.origin, size: newSize)

            notifyWindowResized(window, with: updatedFrame)
        }
    }

    /// Applies a relative resize request while preserving the client-requested aspect ratio.
    @MainActor
    func handleRelativeResize(_ window: MirageMedia.MirageWindow, event: MirageInput.MirageRelativeResizeEvent) {
        guard let windowController else { return }
        if hostService?.isStreamUsingVirtualDisplay(windowID: window.id) == true {
            MirageLogger.host(
                "Ignoring relative resize for window \(window.id) using dedicated virtual display"
            )
            return
        }
        guard let axWindow = windowController.cachedAXWindow(for: window),
              let visibleFrame = windowController.maxWindowSizeRect(for: window) else {
            return
        }

        let clientAspectRatio = event.aspectRatio
        let hostScale = windowController.screenScaleFactor(for: window)

        let initialTargetSize: CGSize
        if event.pixelWidth > 0, event.pixelHeight > 0 {
            let rawSize = CGSize(
                width: CGFloat(event.pixelWidth) / hostScale,
                height: CGFloat(event.pixelHeight) / hostScale
            )
            initialTargetSize = windowController.constrainSizeToFrame(rawSize, frame: visibleFrame)
        } else {
            let minSize = windowController.minimumSize(for: window.id) ?? CGSize(width: 400, height: 300)
            initialTargetSize = windowController.calculateHostWindowSize(
                aspectRatio: clientAspectRatio,
                relativeScale: event.relativeScale,
                visibleFrame: visibleFrame,
                minSize: minSize
            )
        }

        let windowID = window.id
        activeRelativeResizeTaskByWindowID[windowID]?.cancel()

        let task = Task {
            try Task.checkCancellation()

            var mutableSize = initialTargetSize
            guard let sizeValue = AXValueCreate(.cgSize, &mutableSize) else { return }
            let setResult = AXUIElementSetAttributeValue(axWindow, kAXSizeAttribute as CFString, sizeValue)
            guard setResult == .success else { return }

            try await Task.sleep(for: .milliseconds(20))

            let size = (windowController.axWindowFrame(axWindow) ?? windowController
                .currentWindowFrame(for: windowID))?.size ?? initialTargetSize

            let captureWidth = Int(size.width * hostScale)
            let captureHeight = Int(size.height * hostScale)

            if captureWidth > 0, captureHeight > 0 {
                windowController.scheduleResizeUpdate(windowID: windowID, width: captureWidth, height: captureHeight)
            }

            _ = windowController.centerWindowOnScreen(axWindow, newSize: size, windowID: windowID)
            windowController.requestFrameEnforcement(for: window, targetSize: size)
        }
        activeRelativeResizeTaskByWindowID[windowID] = task
    }

    /// Applies a pixel-size resize request to a directly captured host window.
    @MainActor
    func handlePixelResize(_ window: MirageMedia.MirageWindow, event: MirageInput.MiragePixelResizeEvent) {
        guard let windowController else { return }
        if hostService?.isStreamUsingVirtualDisplay(windowID: window.id) == true {
            MirageLogger.host(
                "Ignoring pixel resize for window \(window.id) using dedicated virtual display"
            )
            return
        }
        guard let axWindow = windowController.cachedAXWindow(for: window) else { return }

        let hostScale = windowController.screenScaleFactor(for: window)
        let targetSize = CGSize(
            width: CGFloat(event.pixelWidth) / hostScale,
            height: CGFloat(event.pixelHeight) / hostScale
        )

        var mutableSize = targetSize
        guard let sizeValue = AXValueCreate(.cgSize, &mutableSize) else { return }

        let result = AXUIElementSetAttributeValue(axWindow, kAXSizeAttribute as CFString, sizeValue)

        if result == .success {
            _ = windowController.centerWindowOnScreen(axWindow, newSize: targetSize, windowID: window.id)
            windowController.requestFrameEnforcement(for: window, targetSize: targetSize)

            Task { [weak self] in
                await self?.hostService?.updateCaptureResolution(
                    for: window.id,
                    width: event.pixelWidth,
                    height: event.pixelHeight
                )
            }
        }
    }

    /// Notifies the host service after an accessibility resize changes a streamed window frame.
    @MainActor
    private func notifyWindowResized(_ window: MirageMedia.MirageWindow, with updatedFrame: CGRect) {
        let updatedWindow = MirageMedia.MirageWindow(
            id: window.id,
            title: window.title,
            application: window.application,
            frame: updatedFrame,
            isOnScreen: window.isOnScreen,
            windowLayer: window.windowLayer
        )

        Task { [weak self] in
            await self?.hostService?.notifyWindowResized(updatedWindow)
        }
    }
}

#endif
