//
//  AppAtlasMediaCoordinator+Auxiliary.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/13/26.
//
//  Auxiliary overlay capture and composition for app-atlas media streams.
//

import CoreMedia
import CoreVideo
import Foundation
import MirageKit

#if os(macOS)
/// Auxiliary window capture, routing, and overlay composition for app-atlas streams.
extension AppAtlasMediaCoordinator {
    /// Returns the primary and auxiliary host window IDs currently captured for a logical stream.
    func capturedWindowIDs(streamID: StreamID) -> [WindowID] {
        guard let windowID = windowIDByStreamID[streamID] else { return [] }
        let auxiliaryWindowIDs = auxiliaryWindowIDsByParentWindowID[windowID] ?? []
        var result = [windowID]
        for auxiliaryWindowID in auxiliaryWindowIDs.sorted() where auxiliaryWindowID != windowID {
            result.append(auxiliaryWindowID)
        }
        return result
    }

    /// Adds or updates an auxiliary overlay capture for a parent logical stream.
    func updateAuxiliaryOverlay(
        parentStreamID: StreamID,
        candidate: AppStreamWindowCandidate,
        windowWrapper: SCWindowWrapper,
        applicationWrapper: SCApplicationWrapper,
        displayWrapper: SCDisplayWrapper
    ) async throws {
        guard !isStopped else { throw CancellationError() }
        guard let parentWindowID = windowIDByStreamID[parentStreamID],
              logicalWindowsByWindowID[parentWindowID] != nil else {
            throw MirageError.protocolError("App-atlas parent stream \(parentStreamID) is not bound to a logical window")
        }

        let auxiliaryWindowID = WindowID(windowWrapper.window.windowID)
        let auxiliaryApplication = MirageApplication(
            id: applicationWrapper.application.processID,
            bundleIdentifier: applicationWrapper.application.bundleIdentifier,
            name: applicationWrapper.application.applicationName
        )
        let auxiliaryWindow = MirageWindow(
            id: auxiliaryWindowID,
            title: windowWrapper.window.title ?? candidate.window.title,
            application: auxiliaryApplication,
            frame: currentWindowFrame(for: auxiliaryWindowID) ?? windowWrapper.window.frame,
            isOnScreen: windowWrapper.window.isOnScreen,
            windowLayer: Int(windowWrapper.window.windowLayer)
        )

        if auxiliaryCapturesByWindowID[auxiliaryWindowID] == nil {
            let captureContext = AppAtlasWindowCaptureContext()
            auxiliaryCapturesByWindowID[auxiliaryWindowID] = captureContext
            do {
                try await captureContext.startCapture(
                    windowWrapper: windowWrapper,
                    applicationWrapper: applicationWrapper,
                    displayWrapper: displayWrapper,
                    encoderConfig: encoderConfig,
                    latencyMode: latencyMode,
                    capturePressureProfile: capturePressureProfile,
                    targetFrameRate: targetFrameRate,
                    onFrame: { [weak self] frame in
                        Task(priority: .userInitiated) {
                            await self?.setLatestAuxiliaryFrame(frame, windowID: auxiliaryWindowID)
                        }
                    }
                )
            } catch {
                auxiliaryCapturesByWindowID.removeValue(forKey: auxiliaryWindowID)
                await captureContext.stop()
                throw error
            }
        }

        if let previousOverlay = auxiliaryOverlaysByWindowID[auxiliaryWindowID],
           previousOverlay.parentWindowID != parentWindowID {
            auxiliaryWindowIDsByParentWindowID[previousOverlay.parentWindowID]?.remove(auxiliaryWindowID)
            if let previousParent = logicalWindowsByWindowID[previousOverlay.parentWindowID] {
                await publishAuxiliaryOverlayRegions(parentStreamID: previousParent.streamID, parentWindowID: previousParent.windowID)
            }
        }

        refreshParentScreenFrame(parentWindowID: parentWindowID)
        let overlay = makeAuxiliaryOverlay(
            parentStreamID: parentStreamID,
            parentWindowID: parentWindowID,
            candidate: candidate,
            auxiliaryWindow: auxiliaryWindow
        )
        auxiliaryOverlaysByWindowID[auxiliaryWindowID] = overlay
        auxiliaryWindowIDsByParentWindowID[parentWindowID, default: []].insert(auxiliaryWindowID)
        await publishAuxiliaryOverlayRegions(parentStreamID: parentStreamID, parentWindowID: parentWindowID)
    }

    /// Removes an auxiliary overlay and returns the parent logical stream that changed.
    func removeAuxiliaryOverlay(windowID: WindowID) async -> StreamID? {
        guard let overlay = auxiliaryOverlaysByWindowID.removeValue(forKey: windowID) else { return nil }
        auxiliaryWindowIDsByParentWindowID[overlay.parentWindowID]?.remove(windowID)
        if auxiliaryWindowIDsByParentWindowID[overlay.parentWindowID]?.isEmpty == true {
            auxiliaryWindowIDsByParentWindowID.removeValue(forKey: overlay.parentWindowID)
        }
        latestAuxiliaryFramesByWindowID.removeValue(forKey: windowID)
        let capture = auxiliaryCapturesByWindowID.removeValue(forKey: windowID)
        await capture?.stop()
        await publishAuxiliaryOverlayRegions(parentStreamID: overlay.parentStreamID, parentWindowID: overlay.parentWindowID)
        return overlay.parentStreamID
    }

    /// Stores the latest frame for an auxiliary overlay window.
    func setLatestAuxiliaryFrame(_ frame: CapturedFrame, windowID: WindowID) async {
        latestAuxiliaryFramesByWindowID[windowID] = frame
    }

    /// Builds overlay metadata by projecting an auxiliary host frame into its parent capture surface.
    func makeAuxiliaryOverlay(
        parentStreamID: StreamID,
        parentWindowID: WindowID,
        candidate: AppStreamWindowCandidate,
        auxiliaryWindow: MirageWindow
    ) -> AppAtlasAuxiliaryOverlay {
        let parent = logicalWindowsByWindowID[parentWindowID]
        let destinationRect = parent.map { parent in
            Self.auxiliaryOverlayDestinationRect(
                parentFrame: parent.screenFrame,
                parentSourceRect: parent.sourceRect,
                auxiliaryFrame: auxiliaryWindow.frame
            )
        } ?? .zero
        let normalizedInputRect = parent.map { parent in
            Self.normalizedOverlayInputRect(
                destinationRect: destinationRect,
                parentSourceRect: parent.sourceRect
            )
        } ?? .zero
        return AppAtlasAuxiliaryOverlay(
            windowID: auxiliaryWindow.id,
            parentStreamID: parentStreamID,
            parentWindowID: parentWindowID,
            window: auxiliaryWindow,
            isFocused: candidate.isFocused,
            isMain: candidate.isMain,
            isModal: candidate.isModal,
            windowLayer: auxiliaryWindow.windowLayer,
            windowListOrder: candidate.windowListOrder,
            destinationRect: destinationRect,
            normalizedInputRect: normalizedInputRect
        )
    }

    /// Refreshes the parent host frame used to project auxiliary overlay geometry.
    func refreshParentScreenFrame(parentWindowID: WindowID) {
        guard var parent = logicalWindowsByWindowID[parentWindowID],
              let currentFrame = currentWindowFrame(for: parentWindowID),
              currentFrame.width > 0,
              currentFrame.height > 0 else {
            return
        }
        parent.screenFrame = currentFrame
        parent.pointSize = currentFrame.size
        logicalWindowsByWindowID[parentWindowID] = parent
    }

    /// Recomputes all auxiliary overlay rectangles for one parent after parent capture geometry changes.
    func recomputeAuxiliaryOverlayGeometry(parentWindowID: WindowID) {
        guard let parent = logicalWindowsByWindowID[parentWindowID],
              let auxiliaryWindowIDs = auxiliaryWindowIDsByParentWindowID[parentWindowID] else {
            return
        }
        for auxiliaryWindowID in auxiliaryWindowIDs {
            guard var overlay = auxiliaryOverlaysByWindowID[auxiliaryWindowID] else { continue }
            overlay.destinationRect = Self.auxiliaryOverlayDestinationRect(
                parentFrame: parent.screenFrame,
                parentSourceRect: parent.sourceRect,
                auxiliaryFrame: overlay.window.frame
            )
            overlay.normalizedInputRect = Self.normalizedOverlayInputRect(
                destinationRect: overlay.destinationRect,
                parentSourceRect: parent.sourceRect
            )
            auxiliaryOverlaysByWindowID[auxiliaryWindowID] = overlay
        }
    }

    /// Publishes client input-routing regions for the auxiliary overlays on a parent stream.
    func publishAuxiliaryOverlayRegions(parentStreamID: StreamID, parentWindowID: WindowID) async {
        let overlays = auxiliaryOverlaysForComposition(parentWindowID: parentWindowID).reversed()
        let overlaysArray = Array(overlays)
        let count = overlaysArray.count
        let regions = overlaysArray.enumerated().map { index, overlay in
            AppStreamInputOverlayRegion(
                window: overlay.window,
                normalizedRect: overlay.normalizedInputRect,
                zIndex: count - index,
                receivesKeyboardFocus: overlay.receivesKeyboardFocus
            )
        }
        await publishOverlayRegions(parentStreamID, regions)
    }

    /// Removes all auxiliary overlays associated with a parent logical window.
    func removeAuxiliaryOverlays(parentWindowID: WindowID, publishEmptyForStreamID streamID: StreamID) async {
        let auxiliaryWindowIDs = auxiliaryWindowIDsByParentWindowID.removeValue(forKey: parentWindowID) ?? []
        var capturesToStop: [AppAtlasWindowCaptureContext] = []
        for auxiliaryWindowID in auxiliaryWindowIDs {
            auxiliaryOverlaysByWindowID.removeValue(forKey: auxiliaryWindowID)
            latestAuxiliaryFramesByWindowID.removeValue(forKey: auxiliaryWindowID)
            if let capture = auxiliaryCapturesByWindowID.removeValue(forKey: auxiliaryWindowID) {
                capturesToStop.append(capture)
            }
        }
        for capture in capturesToStop {
            await capture.stop()
        }
        await publishOverlayRegions(streamID, [])
    }

    /// Returns primary frames after compositing any available auxiliary overlays onto their parents.
    func framesByCompositingAuxiliaryOverlays(
        using compositor: AppAtlasFrameCompositor
    ) throws -> [WindowID: CapturedFrame] {
        var framesByWindowID = latestFramesByWindowID

        for parentWindow in logicalWindowsByWindowID.values {
            guard let baseFrame = latestFramesByWindowID[parentWindow.windowID] else { continue }
            let overlayFrames = auxiliaryOverlaysForComposition(parentWindowID: parentWindow.windowID).compactMap { overlay -> AppAtlasFrameCompositor.OverlayFrame? in
                guard let frame = latestAuxiliaryFramesByWindowID[overlay.windowID] else { return nil }
                let sourceRect = CGRect(
                    x: 0,
                    y: 0,
                    width: CVPixelBufferGetWidth(frame.pixelBuffer),
                    height: CVPixelBufferGetHeight(frame.pixelBuffer)
                )
                return AppAtlasFrameCompositor.OverlayFrame(
                    frame: frame,
                    sourceRect: sourceRect,
                    destinationRect: overlay.destinationRect
                )
            }
            guard !overlayFrames.isEmpty else { continue }

            let compositePixelBuffer = try compositor.compose(
                baseFrame: baseFrame,
                overlays: overlayFrames,
                outputSize: parentWindow.pixelSize
            )
            let contributingFrames = [baseFrame] + overlayFrames.map(\.frame)
            let presentationTime = contributingFrames
                .map(\.presentationTime)
                .max { CMTimeCompare($0, $1) < 0 } ?? baseFrame.presentationTime
            let captureTime = contributingFrames
                .map(\.captureTime)
                .max() ?? baseFrame.captureTime
            framesByWindowID[parentWindow.windowID] = CapturedFrame(
                pixelBuffer: compositePixelBuffer,
                presentationTime: presentationTime,
                duration: baseFrame.duration,
                captureTime: captureTime,
                info: CapturedFrameInfo(
                    contentRect: CGRect(origin: .zero, size: parentWindow.pixelSize),
                    dirtyPercentage: 100,
                    isIdleFrame: false
                )
            )
        }

        return framesByWindowID
    }

    /// Returns finite overlays for a parent in composition order.
    func auxiliaryOverlaysForComposition(parentWindowID: WindowID) -> [AppAtlasAuxiliaryOverlay] {
        (auxiliaryWindowIDsByParentWindowID[parentWindowID] ?? [])
            .compactMap { auxiliaryOverlaysByWindowID[$0] }
            .filter { Self.isFiniteNonEmptyRect($0.destinationRect) }
            .sorted { lhs, rhs in
                if lhs.windowListOrder != rhs.windowListOrder {
                    return lhs.windowListOrder > rhs.windowListOrder
                }
                if lhs.windowLayer != rhs.windowLayer {
                    return lhs.windowLayer < rhs.windowLayer
                }
                return lhs.windowID < rhs.windowID
            }
    }
}
#endif
