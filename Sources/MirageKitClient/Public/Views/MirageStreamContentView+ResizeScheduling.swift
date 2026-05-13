//
//  MirageStreamContentView+ResizeScheduling.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/9/26.
//

import Foundation
import MirageKit
import SwiftUI
#if os(macOS)
import AppKit
#endif
#if os(iOS) || os(visionOS)
import UIKit
#endif

// MARK: - Resize Scheduling

extension MirageStreamContentView {
    func scheduleDrawableMetricsChanged(_ metrics: MirageDrawableMetrics) {
        Task { @MainActor in
            await Task.yield()
            handleDrawableMetricsChanged(metrics)
        }
    }

    func scheduleContainerSizeChanged(_ containerSize: CGSize) {
        Task { @MainActor in
            await Task.yield()
            handleContainerSizeChanged(containerSize, lifecycleEvent: .containerSizeChanged)
        }
    }

    func scheduleDesktopResizeForCurrentMetricsIfNeeded() {
        let containerSize = latestContainerDisplaySize.width > 0 && latestContainerDisplaySize.height > 0
            ? latestContainerDisplaySize
            : latestDrawableViewSize
        guard containerSize.width > 0, containerSize.height > 0 else { return }
        scheduleContainerSizeChanged(containerSize)
    }

    func handleDrawableMetricsChanged(_ metrics: MirageDrawableMetrics) {
        guard metrics.pixelSize.width > 0, metrics.pixelSize.height > 0 else { return }

        let viewSize = metrics.viewSize
        let resolvedRawPixelSize = metrics.pixelSize
        latestDrawableViewSize = viewSize

        #if os(iOS) || os(visionOS)
        if resolvedRawPixelSize.width > 0, resolvedRawPixelSize.height > 0 {
            MirageClientService.lastKnownDrawablePixelSize = resolvedRawPixelSize
        }
        if let screenPointSize = metrics.screenPointSize,
           screenPointSize.width > 0,
           screenPointSize.height > 0 {
            MirageClientService.lastKnownScreenPointSize = screenPointSize
        }
        if let screenScale = metrics.screenScale, screenScale > 0 {
            MirageClientService.lastKnownScreenScale = screenScale
        }
        if let nativePixelSize = metrics.screenNativePixelSize,
           nativePixelSize.width > 0,
           nativePixelSize.height > 0 {
            MirageClientService.lastKnownScreenNativePixelSize = nativePixelSize
        }
        if let nativeScale = metrics.screenNativeScale, nativeScale > 0 {
            MirageClientService.lastKnownScreenNativeScale = nativeScale
        }
        #endif

        if isDesktopStream {
            let targetSize = latestContainerDisplaySize.width > 0 && latestContainerDisplaySize.height > 0
                ? latestContainerDisplaySize
                : viewSize
            handleContainerSizeChanged(targetSize, lifecycleEvent: .drawableMetricsChanged)
        } else if latestContainerDisplaySize.width <= 0 || latestContainerDisplaySize.height <= 0 {
            handleContainerSizeChanged(viewSize, lifecycleEvent: .drawableMetricsChanged)
        }
    }

    func handleContainerSizeChanged(
        _ containerSize: CGSize,
        lifecycleEvent: DesktopResizeLifecycleEvent
    ) {
        if containerSize.width > 0, containerSize.height > 0 {
            latestContainerDisplaySize = containerSize
            #if os(iOS) || os(visionOS)
            MirageClientService.lastKnownViewSize = containerSize
            #endif
        }

        #if os(iOS) || os(visionOS)
        let currentLifecycleState = isDesktopStream
            ? desktopResizeCoordinator.resizeLifecycleState
            : resizeLifecycleState
        let lifecycleDecision = desktopResizeLifecycleDecision(
            state: currentLifecycleState,
            event: lifecycleEvent
        )
        if isDesktopStream {
            desktopResizeCoordinator.resizeLifecycleState = lifecycleDecision.nextState
        } else {
            resizeLifecycleState = lifecycleDecision.nextState
        }
        guard lifecycleDecision.shouldProcessDrawableMetrics else { return }
        #endif

        if suppressesWindowDrivenResizeForLocalPresentation {
            cancelPendingWindowDrivenResizeForLocalPresentation()
            return
        }

        let targetViewSize = if containerSize.width > 0, containerSize.height > 0 {
            containerSize
        } else {
            latestDrawableViewSize
        }
        guard targetViewSize.width > 0, targetViewSize.height > 0 else {
            if !isDesktopStream {
                if !awaitingAppResizeAck, isResizing { isResizing = false }
            }
            return
        }

        Task { @MainActor [clientService] in
            await Task.yield()
            do {
                try await Task.sleep(for: .milliseconds(1))
            } catch {
                return
            }
            let lifecycleState = isDesktopStream
                ? desktopResizeCoordinator.resizeLifecycleState
                : resizeLifecycleState
            guard lifecycleState == .active else { return }

            #if os(visionOS)
            let visionOSDisplaySize = clientService.visionOSFixedPixelCountResolution(for: targetViewSize)
            #endif
            let desktopDisplaySize = isDesktopStream
                ? clientService.preferredDesktopDisplayResolution(for: targetViewSize)
                : .zero
            if !isDesktopStream {
                #if os(visionOS)
                let baseDisplaySize = visionOSDisplaySize
                #else
                let baseDisplaySize = MirageStreamGeometry.normalizedLogicalSize(targetViewSize)
                #endif
                guard baseDisplaySize.width > 0, baseDisplaySize.height > 0 else {
                    if isResizing, !awaitingAppResizeAck { isResizing = false }
                    return
                }
                if streamPresentationTier == .passiveSnapshot {
                    displayResolutionTask?.cancel()
                    displayResolutionTask = nil
                    pendingDisplayResolutionDispatchTarget = .zero
                    if awaitingAppResizeAck {
                        finishAppResizeAwaitingAck()
                    } else if isResizing {
                        isResizing = false
                    }
                    return
                }

                // Dedicated app/window virtual-display streams now resize via display-resolution
                // updates only. Suppress dynamic stream-scale pushes that can fight placement.
                streamScaleTask?.cancel()
                streamScaleTask = nil
                lastSentEncodedPixelSize = .zero
                guard lastSentDisplayResolution != baseDisplaySize else {
                    if isResizing, !awaitingAppResizeAck { isResizing = false }
                    return
                }
                enqueueImmediateAppDisplayResolutionChange(baseDisplaySize)
                return
            }

            guard isDesktopStream else { return }

            #if os(visionOS)
            let preferredDisplaySize = visionOSDisplaySize
            #else
            let preferredDisplaySize = desktopDisplaySize
            #endif
            let target = clientService.desktopResizeTarget(
                for: preferredDisplaySize,
                maxDrawableSize: maxDrawableSize
            )
            clientService.queueDesktopResize(
                streamID: session.streamID,
                target: target,
                hasPresentedFrame: session.hasPresentedFrame,
                useHostResolution: useHostResolution
            )
        }
    }

    func enqueueImmediateAppDisplayResolutionChange(_ targetDisplaySize: CGSize) {
        guard targetDisplaySize.width > 0, targetDisplaySize.height > 0 else { return }
        guard pendingDisplayResolutionDispatchTarget != targetDisplaySize || displayResolutionTask == nil else { return }

        pendingDisplayResolutionDispatchTarget = targetDisplaySize
        guard displayResolutionTask == nil else { return }

        displayResolutionTask = Task { @MainActor [clientService] in
            defer {
                displayResolutionTask = nil
                if pendingDisplayResolutionDispatchTarget == .zero, isResizing, !awaitingAppResizeAck {
                    isResizing = false
                }
            }

            while !Task.isCancelled {
                let dispatchedTarget = pendingDisplayResolutionDispatchTarget
                pendingDisplayResolutionDispatchTarget = .zero
                guard dispatchedTarget.width > 0, dispatchedTarget.height > 0 else { break }

                guard lastSentDisplayResolution != dispatchedTarget else {
                    if pendingDisplayResolutionDispatchTarget == .zero { break }
                    continue
                }

                lastSentDisplayResolution = dispatchedTarget
                beginAppResizeAwaitingAck()
                do {
                    try await clientService.sendDisplayResolutionChange(
                        streamID: session.streamID,
                        newResolution: dispatchedTarget
                    )
                } catch {
                    finishAppResizeAwaitingAck()
                }

                if pendingDisplayResolutionDispatchTarget == .zero { break }
                await Task.yield()
            }
        }
    }

    func beginAppResizeAwaitingAck() {
        appResizeBaselineAcknowledgement = clientService.appStreamStartAcknowledgementByStreamID[session.streamID]
        awaitingAppResizeAck = true
        isResizing = true
        appResizeAckTimeoutTask?.cancel()
        appResizeAckTimeoutTask = Task { @MainActor in
            do {
                try await Task.sleep(for: Self.appResizeAckTimeout)
            } catch {
                return
            }
            guard awaitingAppResizeAck else { return }
            finishAppResizeAwaitingAck()
        }
    }

    func finishAppResizeAwaitingAck() {
        appResizeAckTimeoutTask?.cancel()
        appResizeAckTimeoutTask = nil
        awaitingAppResizeAck = false
        appResizeBaselineAcknowledgement = nil
        if isResizing { isResizing = false }
    }

    func cancelPendingWindowDrivenResizeForLocalPresentation() {
        if isDesktopStream {
            clientService.cancelQueuedDesktopResizeForLocalPresentation(streamID: session.streamID)
            return
        }

        displayResolutionTask?.cancel()
        displayResolutionTask = nil
        pendingDisplayResolutionDispatchTarget = .zero
        streamScaleTask?.cancel()
        streamScaleTask = nil
        if awaitingAppResizeAck {
            finishAppResizeAwaitingAck()
        } else if isResizing {
            isResizing = false
        }
    }
}
