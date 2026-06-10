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
        scheduleWindowDrivenResizeForCurrentMetricsIfNeeded()
    }

    func scheduleWindowDrivenResizeForCurrentMetricsIfNeeded() {
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
        if metrics.scaleFactor > 0 {
            latestDrawableScaleFactor = metrics.scaleFactor
        }

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
            guard latestContainerDisplaySize.width <= 0 || latestContainerDisplaySize.height <= 0 else { return }
            handleContainerSizeChanged(viewSize, lifecycleEvent: .drawableMetricsChanged)
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
            guard !suppressesWindowDrivenResizeForLocalPresentation else {
                cancelPendingWindowDrivenResizeForLocalPresentation()
                return
            }

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
                    appResizeDispatchState.cancel()
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
                maxDrawableSize: maxDrawableSize,
                displayScaleFactor: nil
            )
            let dispatchPolicy = desktopResizeDispatchPolicy(for: target)
            clientService.queueDesktopResize(
                streamID: session.streamID,
                target: target,
                hasPresentedFrame: session.hasPresentedFrame,
                useHostResolution: useHostResolution,
                dispatchPolicy: dispatchPolicy
            )
        }
    }

    func desktopResizeDispatchPolicy(
        for _: DesktopResizeCoordinator.RequestGeometry?
    ) -> DesktopResizeCoordinator.DispatchPolicy {
        return .settledWindowMetrics
    }

    func enqueueImmediateAppDisplayResolutionChange(_ targetDisplaySize: CGSize) {
        guard targetDisplaySize.width > 0, targetDisplaySize.height > 0 else { return }
        appResizeDispatchState.enqueue(targetDisplaySize)
        scheduleAppDisplayResolutionDispatchIfNeeded()
    }

    func scheduleAppDisplayResolutionDispatchIfNeeded() {
        guard displayResolutionTask == nil else { return }
        guard !appResizeDispatchState.hasInFlightResize else { return }
        let now = CFAbsoluteTimeGetCurrent()
        guard let delay = appResizeDispatchState.dispatchDelay(now: now) else { return }

        displayResolutionTask = Task { @MainActor [clientService] in
            defer {
                displayResolutionTask = nil
            }

            if delay > 0 {
                do {
                    try await Task.sleep(for: .milliseconds(Int((delay * 1000).rounded(.up))))
                } catch {
                    return
                }
            }

            guard !Task.isCancelled else { return }
            guard !suppressesWindowDrivenResizeForLocalPresentation,
                  streamPresentationTier != .passiveSnapshot else {
                cancelPendingWindowDrivenResizeForLocalPresentation()
                return
            }

            guard let dispatchedTarget = appResizeDispatchState.beginNextDispatch(
                now: CFAbsoluteTimeGetCurrent()
            ) else {
                if isResizing, !awaitingAppResizeAck { isResizing = false }
                return
            }

            beginAppResizeAwaitingAck()
            do {
                try await clientService.sendDisplayResolutionChange(
                    streamID: session.streamID,
                    newResolution: dispatchedTarget
                )
                MirageLogger.client(
                    "App resize dispatched stream=\(session.streamID) target=\(Int(dispatchedTarget.width))x\(Int(dispatchedTarget.height)) " +
                        appResizeDispatchState.diagnosticSummary
                )
            } catch {
                appResizeDispatchState.completeCurrentAsSendFailed(now: CFAbsoluteTimeGetCurrent())
                finishAppResizeAwaitingAck()
                Task { @MainActor in
                    await Task.yield()
                    scheduleAppDisplayResolutionDispatchIfNeeded()
                }
            }
        }
    }

    func beginAppResizeAwaitingAck() {
        appResizeBaselineAcknowledgement = appStreamStartAcknowledgement
        awaitingAppResizeAck = true
        isResizing = true
        onAppResizeWaitingChanged?(true)
        appResizeAckTimeoutTask?.cancel()
        appResizeAckTimeoutTask = Task { @MainActor in
            do {
                try await Task.sleep(for: Self.appResizeAckTimeout)
            } catch {
                return
            }
            guard awaitingAppResizeAck else { return }
            appResizeDispatchState.completeCurrentAsTimedOut(now: CFAbsoluteTimeGetCurrent())
            MirageLogger.client(
                "App resize ack timed out stream=\(session.streamID) " +
                    appResizeDispatchState.diagnosticSummary
            )
            finishAppResizeAwaitingAck()
            scheduleAppDisplayResolutionDispatchIfNeeded()
        }
    }

    func finishAppResizeAwaitingAck() {
        appResizeAckTimeoutTask?.cancel()
        appResizeAckTimeoutTask = nil
        awaitingAppResizeAck = false
        appResizeBaselineAcknowledgement = nil
        if isResizing { isResizing = false }
        onAppResizeWaitingChanged?(false)
    }

    func cancelPendingWindowDrivenResizeForLocalPresentation() {
        if isDesktopStream {
            clientService.cancelQueuedDesktopResizeForLocalPresentation(streamID: session.streamID)
            return
        }

        displayResolutionTask?.cancel()
        displayResolutionTask = nil
        appResizeDispatchState.cancel()
        streamScaleTask?.cancel()
        streamScaleTask = nil
        if awaitingAppResizeAck {
            finishAppResizeAwaitingAck()
        } else if isResizing {
            isResizing = false
        }
    }
}
