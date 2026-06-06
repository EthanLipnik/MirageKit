//
//  StreamContext+TrafficLightStamping.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/9/26.
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
import CoreVideo
import Foundation

#if os(macOS)

extension StreamContext {
    func applyTrafficLightCloneStampIfNeeded(frame: CapturedFrame) async {
        guard isAppStream,
              useVirtualDisplay,
              captureMode == .display,
              windowID != 0 else {
            return
        }

        let windowFramePoints = resolvedWindowFramePointsForTrafficLightMask(frame: frame)
        guard windowFramePoints.width > 0, windowFramePoints.height > 0 else { return }
        let contentRect = resolvedContentRectForTrafficLightMask(frame: frame)
        guard contentRect.width > 0, contentRect.height > 0 else { return }

        let geometry = resolveTrafficLightMaskGeometry(windowFramePoints: windowFramePoints)
        let compositor = trafficLightCloneStampCompositor
        let pixelBuffer = frame.pixelBuffer
        let result = await Task.detached(priority: .userInitiated) {
            compositor.apply(
                to: pixelBuffer,
                contentRect: contentRect,
                geometry: geometry
            )
        }.value
        logTrafficLightCloneStampResultIfNeeded(result, geometry: geometry)
    }

    func resolvedWindowFramePointsForTrafficLightMask(frame: CapturedFrame) -> CGRect {
        if !lastWindowFrame.isEmpty, lastWindowFrame.width > 0, lastWindowFrame.height > 0 {
            return lastWindowFrame
        }

        let contentRect = frame.info.contentRect
        guard contentRect.width > 0, contentRect.height > 0 else {
            return .zero
        }

        return CGRect(
            x: 0,
            y: 0,
            width: contentRect.width,
            height: contentRect.height
        )
    }

    func resolvedContentRectForTrafficLightMask(frame: CapturedFrame) -> CGRect {
        let fullFrameRect = CGRect(
            x: 0,
            y: 0,
            width: CVPixelBufferGetWidth(frame.pixelBuffer),
            height: CVPixelBufferGetHeight(frame.pixelBuffer)
        )

        if useVirtualDisplay, isAppStream, captureMode == .display {
            return Self.sharedDisplayAppTrafficLightMaskContentRect(
                primaryRect: lastWindowFrame,
                presentationRect: virtualDisplayCapturePresentationRect,
                contentRect: resolvedOutgoingContentRect(for: frame),
                fullFrameRect: fullFrameRect
            )
        }

        let contentRect = frame.info.contentRect
        if contentRect.width > 0, contentRect.height > 0 {
            return contentRect
        }

        return fullFrameRect
    }

    nonisolated static func sharedDisplayAppTrafficLightMaskContentRect(
        primaryRect: CGRect,
        presentationRect: CGRect,
        contentRect: CGRect,
        fullFrameRect: CGRect
    ) -> CGRect {
        let resolvedFullFrameRect = fullFrameRect.standardized
        let resolvedContentRect = contentRect
            .intersection(resolvedFullFrameRect)
            .standardized
        guard resolvedContentRect.width > 0,
              resolvedContentRect.height > 0 else {
            return resolvedFullFrameRect
        }

        let resolvedPresentationRect = presentationRect.standardized
        guard resolvedPresentationRect.width > 0,
              resolvedPresentationRect.height > 0 else {
            return resolvedContentRect
        }

        let resolvedPrimaryRect = primaryRect
            .standardized
            .intersection(resolvedPresentationRect)
            .standardized
        guard resolvedPrimaryRect.width > 0,
              resolvedPrimaryRect.height > 0 else {
            return resolvedContentRect
        }

        let scaleX = resolvedContentRect.width / resolvedPresentationRect.width
        let scaleY = resolvedContentRect.height / resolvedPresentationRect.height
        let mappedRect = CGRect(
            x: resolvedContentRect.minX + (resolvedPrimaryRect.minX - resolvedPresentationRect.minX) * scaleX,
            y: resolvedContentRect.minY + (resolvedPrimaryRect.minY - resolvedPresentationRect.minY) * scaleY,
            width: resolvedPrimaryRect.width * scaleX,
            height: resolvedPrimaryRect.height * scaleY
        )
        let sanitizedRect = mappedRect
            .intersection(resolvedContentRect)
            .standardized
        guard sanitizedRect.width > 0,
              sanitizedRect.height > 0 else {
            return resolvedContentRect
        }
        return sanitizedRect
    }

    func resolvedOutgoingContentRect(for frame: CapturedFrame) -> CGRect {
        let fullFrameRect = CGRect(
            x: 0,
            y: 0,
            width: CVPixelBufferGetWidth(frame.pixelBuffer),
            height: CVPixelBufferGetHeight(frame.pixelBuffer)
        )
        guard fullFrameRect.width > 0, fullFrameRect.height > 0 else { return .zero }

        if useVirtualDisplay, isAppStream {
            if captureMode == .window {
                return fullFrameRect
            }
            let fixedCanvasContentRect = currentContentRect.intersection(fullFrameRect)
            if captureMode == .display,
               fixedCanvasContentRect.width > 0,
               fixedCanvasContentRect.height > 0 {
                return fixedCanvasContentRect
            }
        }

        let candidate = frame.info.contentRect
        guard candidate.width > 0, candidate.height > 0 else { return fullFrameRect }
        let sanitized = candidate.intersection(fullFrameRect)
        guard sanitized.width > 0, sanitized.height > 0 else { return fullFrameRect }
        return sanitized
    }

    func resolveTrafficLightMaskGeometry(windowFramePoints: CGRect) -> HostTrafficLightMaskGeometryResolver.ResolvedGeometry {
        let now = CFAbsoluteTimeGetCurrent()
        if let cache = trafficLightMaskGeometryCache,
           HostTrafficLightMaskGeometryResolver.shouldUseCached(
               cache,
               now: now,
               windowFramePoints: windowFramePoints,
               ttl: trafficLightMaskGeometryCacheTTL,
               frameTolerance: trafficLightMaskGeometryFrameTolerance
           ) {
            return cache.geometry
        }

        let geometry = HostTrafficLightMaskGeometryResolver.resolve(
            windowID: windowID,
            windowFramePoints: windowFramePoints,
            appProcessID: applicationProcessID > 0 ? applicationProcessID : nil
        )
        trafficLightMaskGeometryCache = HostTrafficLightMaskGeometryResolver.CacheEntry(
            geometry: geometry,
            sampledAt: now,
            sampledWindowFrame: windowFramePoints
        )
        return geometry
    }

    func logTrafficLightCloneStampResultIfNeeded(
        _ result: HostTrafficLightCloneStampCompositor.ApplyResult,
        geometry: HostTrafficLightMaskGeometryResolver.ResolvedGeometry
    ) {
        guard case let .skipped(reason) = result else { return }

        let now = CFAbsoluteTimeGetCurrent()
        if now - lastTrafficLightMaskLogTime < trafficLightMaskLogInterval {
            return
        }
        lastTrafficLightMaskLogTime = now
        MirageLogger.debug(
            .stream,
            "Traffic-light clone-stamp skipped for stream \(streamID) window \(windowID): reason=\(reason.rawValue), source=\(geometry.source.rawValue)"
        )
    }
}

#endif
