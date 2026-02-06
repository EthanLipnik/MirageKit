//
//  MirageHostInputController+Resize.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Host input controller extensions.
//

import CoreGraphics
import Foundation
import MirageKit

#if os(macOS)
import AppKit
import ApplicationServices

extension MirageHostInputController {
    // MARK: - Resize Handling

    @MainActor
    func handleWindowResize(_ window: MirageWindow, resizeEvent: MirageResizeEvent) {
        guard let windowController else { return }
        guard let axWindow = windowController.getOrCacheAXWindow(for: window) else { return }

        let settable = windowController.isWindowSizeSettable(axWindow)
        let minSize = windowController.getMinimumSize(for: window.id)

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
            let updatedFrame = windowController.axWindowFrame(axWindow)
                ?? windowController.currentWindowFrame(for: window.id)
                ?? CGRect(origin: window.frame.origin, size: newSize)

            notifyWindowResized(window, with: updatedFrame)
        }
    }

    @MainActor
    func handleRelativeResize(_ window: MirageWindow, event: MirageRelativeResizeEvent) {
        guard let windowController else { return }
        guard let axWindow = windowController.getOrCacheAXWindow(for: window),
              let visibleFrame = windowController.maxWindowSizeRect(for: window) else {
            return
        }

        let clientAspectRatio = event.aspectRatio
        let isOnVirtualDisplay = hostService?.isStreamUsingVirtualDisplay(windowID: window.id) ?? false
        let hostScale: CGFloat = isOnVirtualDisplay ? 2.0 : (NSScreen.main?.backingScaleFactor ?? 2.0)

        let initialTargetSize: CGSize
        if event.pixelWidth > 0, event.pixelHeight > 0 {
            let rawSize = CGSize(
                width: CGFloat(event.pixelWidth) / hostScale,
                height: CGFloat(event.pixelHeight) / hostScale
            )
            initialTargetSize = windowController.constrainSizeToFrame(rawSize, frame: visibleFrame)
        } else {
            let minSize = windowController.getMinimumSize(for: window.id) ?? CGSize(width: 400, height: 300)
            initialTargetSize = windowController.calculateHostWindowSize(
                aspectRatio: clientAspectRatio,
                relativeScale: event.relativeScale,
                visibleFrame: visibleFrame,
                minSize: minSize
            )
        }

        Task {
            var currentTargetSize = initialTargetSize
            var finalSize: CGSize?

            for _ in 0 ..< 15 {
                var mutableSize = currentTargetSize
                guard let sizeValue = AXValueCreate(.cgSize, &mutableSize) else { break }
                AXUIElementSetAttributeValue(axWindow, kAXSizeAttribute as CFString, sizeValue)

                try? await Task.sleep(for: .milliseconds(30))

                let actualSize = (windowController.axWindowFrame(axWindow) ?? windowController
                    .currentWindowFrame(for: window.id))?.size ?? currentTargetSize

                let actualAspectRatio = actualSize.width / actualSize.height
                let aspectDiff = abs(actualAspectRatio - clientAspectRatio)

                if aspectDiff < 0.02 {
                    finalSize = actualSize
                    break
                }

                let widthConstrained = CGSize(width: actualSize.width, height: actualSize.width / clientAspectRatio)
                let heightConstrained = CGSize(width: actualSize.height * clientAspectRatio, height: actualSize.height)

                let newTarget = widthConstrained.height <= actualSize.height ? widthConstrained : heightConstrained

                if newTarget.width < 200 || newTarget.height < 200 {
                    finalSize = actualSize
                    break
                }

                let sizeDiff = abs(newTarget.width - currentTargetSize.width) +
                    abs(newTarget.height - currentTargetSize.height)
                if sizeDiff < 2 {
                    finalSize = actualSize
                    break
                }

                currentTargetSize = newTarget
            }

            guard let size = finalSize else { return }

            let captureWidth = Int(size.width * hostScale)
            let captureHeight = Int(size.height * hostScale)

            if captureWidth > 0, captureHeight > 0 { windowController.scheduleResizeUpdate(windowID: window.id, width: captureWidth, height: captureHeight) }

            windowController.centerWindowOnScreen(axWindow, newSize: size, windowID: window.id)
        }
    }

    @MainActor
    func handlePixelResize(_ window: MirageWindow, event: MiragePixelResizeEvent) {
        guard let windowController else { return }
        guard let axWindow = windowController.getOrCacheAXWindow(for: window) else { return }

        let hostScale = NSScreen.main?.backingScaleFactor ?? 2.0
        let targetSize = CGSize(
            width: CGFloat(event.pixelWidth) / hostScale,
            height: CGFloat(event.pixelHeight) / hostScale
        )

        var mutableSize = targetSize
        guard let sizeValue = AXValueCreate(.cgSize, &mutableSize) else { return }

        let result = AXUIElementSetAttributeValue(axWindow, kAXSizeAttribute as CFString, sizeValue)

        if result == .success {
            windowController.centerWindowOnScreen(axWindow, newSize: targetSize, windowID: window.id)

            Task { [weak self] in
                await self?.hostService?.updateCaptureResolution(
                    for: window.id,
                    width: event.pixelWidth,
                    height: event.pixelHeight
                )
            }
        }
    }

    @MainActor
    private func notifyWindowResized(_ window: MirageWindow, with updatedFrame: CGRect) {
        let updatedWindow = MirageWindow(
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
