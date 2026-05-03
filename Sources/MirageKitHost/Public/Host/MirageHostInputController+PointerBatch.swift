//
//  MirageHostInputController+PointerBatch.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/3/26.
//
//  Host injection for batched high-rate stylus pointer samples.
//

import CoreGraphics
import Foundation
import MirageKit

#if os(macOS)
import AppKit
import ApplicationServices

extension MirageHostInputController {
    // MARK: - Batched Stylus Injection

    private static let staleHoverBatchInterval: TimeInterval = 0.12

    func injectPointerSampleBatch(
        _ batch: MiragePointerSampleBatch,
        windowFrame: CGRect,
        windowID: WindowID,
        app: MirageApplication?
    ) {
        guard !batch.samples.isEmpty else { return }
        guard !Self.shouldRejectStaleHoverBatch(batch) else { return }

        if batch.isHoverExit {
            if let lastSample = batch.samples.last {
                let point = screenPoint(lastSample.location, in: windowFrame)
                postTabletProximityIfNeeded(entering: false, at: point)
            }
            return
        }

        refreshPointerModifierState(batch.modifiers, domain: .session)
        let resolvedFrame = windowFrame
        let dynamicClusterSize = cachedDynamicTrafficLightClusterSize(
            windowID: windowID,
            app: app,
            windowFrame: resolvedFrame
        )
        let type = Self.pointerEventType(for: batch)

        for sample in batch.samples {
            let localPoint = CGPoint(
                x: sample.location.x * resolvedFrame.width,
                y: sample.location.y * resolvedFrame.height
            )
            if HostTrafficLightProtectionPolicy.shouldBlock(
                eventType: type,
                localPoint: localPoint,
                dynamicClusterSize: dynamicClusterSize
            ) {
                logTrafficLightBlockedEvent(
                    windowID: windowID,
                    eventType: type,
                    localPoint: localPoint,
                    dynamicClusterSize: dynamicClusterSize
                )
                continue
            }

            let screenPoint = CGPoint(
                x: resolvedFrame.origin.x + sample.location.x * resolvedFrame.width,
                y: resolvedFrame.origin.y + sample.location.y * resolvedFrame.height
            )
            postTabletPointerSample(sample, batch: batch, type: type, at: screenPoint)
        }

        if batch.endsContact {
            let point = batch.samples.last.map { screenPoint($0.location, in: resolvedFrame) }
                ?? CGPoint(x: resolvedFrame.midX, y: resolvedFrame.midY)
            postTabletProximityIfNeeded(entering: false, at: point)
        }
    }

    func injectDesktopPointerSampleBatch(_ batch: MiragePointerSampleBatch, bounds: CGRect) {
        guard !batch.samples.isEmpty else { return }
        guard !Self.shouldRejectStaleHoverBatch(batch) else { return }

        if batch.isHoverExit {
            if let lastSample = batch.samples.last {
                let point = screenPoint(lastSample.location, in: bounds)
                postTabletProximityIfNeeded(entering: false, at: point)
            }
            return
        }

        refreshPointerModifierState(batch.modifiers, domain: .hid)
        let type = Self.pointerEventType(for: batch)
        for sample in batch.samples {
            let point = screenPoint(sample.location, in: bounds)
            if Self.shouldWarpDesktopPointerEvent(type) {
                CGWarpMouseCursorPosition(point)
            }
            postTabletPointerSample(sample, batch: batch, type: type, at: point)
        }

        if batch.endsContact {
            let point = batch.samples.last.map { screenPoint($0.location, in: bounds) }
                ?? CGPoint(x: bounds.midX, y: bounds.midY)
            postTabletProximityIfNeeded(entering: false, at: point)
        }
    }

    nonisolated static func pointerEventType(for batch: MiragePointerSampleBatch) -> CGEventType {
        switch batch.phase {
        case .hover:
            .mouseMoved
        case .began:
            pointerDownEventType(for: batch.button)
        case .moved:
            batch.isButtonPressed ? pointerDraggedEventType(for: batch.button) : .mouseMoved
        case .ended,
             .cancelled:
            pointerUpEventType(for: batch.button)
        }
    }

    private nonisolated static func pointerDownEventType(for button: MirageMouseButton) -> CGEventType {
        switch button {
        case .left:
            .leftMouseDown
        case .right:
            .rightMouseDown
        case .middle,
             .button3,
             .button4:
            .otherMouseDown
        }
    }

    private nonisolated static func pointerUpEventType(for button: MirageMouseButton) -> CGEventType {
        switch button {
        case .left:
            .leftMouseUp
        case .right:
            .rightMouseUp
        case .middle,
             .button3,
             .button4:
            .otherMouseUp
        }
    }

    private nonisolated static func pointerDraggedEventType(for button: MirageMouseButton) -> CGEventType {
        switch button {
        case .left:
            .leftMouseDragged
        case .right:
            .rightMouseDragged
        case .middle,
             .button3,
             .button4:
            .otherMouseDragged
        }
    }

    private nonisolated static func shouldRejectStaleHoverBatch(_ batch: MiragePointerSampleBatch) -> Bool {
        guard batch.phase == .hover else { return false }
        let age = Date.timeIntervalSinceReferenceDate - batch.timestamp
        return age > staleHoverBatchInterval
    }
}

private extension MiragePointerSampleBatch {
    var isHoverExit: Bool {
        phase == .cancelled && samples.allSatisfy(\.stylus.isHovering)
    }

    var endsContact: Bool {
        switch phase {
        case .ended, .cancelled:
            !isHoverExit
        case .began, .moved, .hover:
            false
        }
    }
}

#endif
