//
//  MirageHostInputController+Mouse.swift
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
    // MARK: - Mouse Event Injection (runs on accessibilityQueue)

    func refreshPointerModifierState(
        _ modifiers: MirageModifierFlags,
        domain: HostKeyboardInjectionDomain
    ) {
        if modifiers != lastSentModifiers {
            injectFlagsChanged(modifiers, domain: domain, app: nil)
            return
        }

        guard !modifiers.isEmpty else { return }
        let now = CACurrentMediaTime()
        for (flag, _) in Self.modifierKeyCodes where modifiers.contains(flag) {
            modifierLastEventTimes[flag] = now
        }
    }

    func applyPointerEventMetadata(
        _ cgEvent: CGEvent,
        from event: MirageMouseEvent,
        type: CGEventType
    ) {
        cgEvent.flags = event.modifiers.cgEventFlags

        switch type {
        case .leftMouseDown,
             .leftMouseUp,
             .otherMouseDown,
             .otherMouseUp,
             .rightMouseDown,
             .rightMouseUp:
            cgEvent.setIntegerValueField(.mouseEventClickState, value: Int64(event.clickCount))
        default:
            break
        }
    }

    func injectMouseEvent(
        _ type: CGEventType,
        _ event: MirageMouseEvent,
        _ windowFrame: CGRect,
        windowID: WindowID,
        app: MirageApplication?
    ) {
        refreshPointerModifierState(event.modifiers, domain: .session)

        let resolvedFrame: CGRect
        if appliesTabletSubtype(event) {
            // Stylus input is absolute and high-frequency; use the stream frame directly
            // to avoid occasional frame-query jitter while drawing.
            resolvedFrame = windowFrame
        } else {
            // Throttle CGWindowList frame validation to keep drag/move input path hot.
            resolvedFrame = resolvedInputWindowFrame(for: windowID, streamFrame: windowFrame)
        }

        let localPoint = CGPoint(
            x: event.location.x * resolvedFrame.width,
            y: event.location.y * resolvedFrame.height
        )
        let dynamicClusterSize = cachedDynamicTrafficLightClusterSize(
            windowID: windowID,
            app: app,
            windowFrame: resolvedFrame
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
            return
        }

        let screenPoint = CGPoint(
            x: resolvedFrame.origin.x + event.location.x * resolvedFrame.width,
            y: resolvedFrame.origin.y + event.location.y * resolvedFrame.height
        )

        switch type {
        case .leftMouseDown,
             .otherMouseDown,
             .rightMouseDown:
            CGWarpMouseCursorPosition(screenPoint)
        default:
            break
        }

        guard let cgEvent = CGEvent(
            mouseEventSource: nil,
            mouseType: type,
            mouseCursorPosition: screenPoint,
            mouseButton: event.button.cgMouseButton
        ) else {
            return
        }

        applyPointerEventMetadata(cgEvent, from: event, type: type)
        applyTabletFieldsIfNeeded(cgEvent, from: event, type: type, point: screenPoint)
        postStylusAwarePointerEvent(cgEvent, from: event, type: type, at: screenPoint)
    }

    private func cachedDynamicTrafficLightClusterSize(
        windowID: WindowID,
        app: MirageApplication?,
        windowFrame: CGRect
    ) -> CGSize? {
        let now = CFAbsoluteTimeGetCurrent()
        if let cached = trafficLightClusterCacheByWindowID[windowID],
           now - cached.sampledAt <= trafficLightClusterCacheTTL,
           framesAreClose(cached.sampledWindowFrame, windowFrame, tolerance: 6) {
            return cached.dynamicClusterSize
        }

        let dynamicClusterSize = dynamicTrafficLightClusterSize(
            windowID: windowID,
            app: app,
            windowFrame: windowFrame
        )
        trafficLightClusterCacheByWindowID[windowID] = CachedTrafficLightClusterGeometry(
            dynamicClusterSize: dynamicClusterSize,
            sampledWindowFrame: windowFrame,
            sampledAt: now
        )
        return dynamicClusterSize
    }

    private func logTrafficLightBlockedEvent(
        windowID: WindowID,
        eventType: CGEventType,
        localPoint: CGPoint,
        dynamicClusterSize: CGSize?
    ) {
        let now = CFAbsoluteTimeGetCurrent()
        if let lastLogTime = lastTrafficLightBlockedLogTimeByWindowID[windowID],
           now - lastLogTime < trafficLightBlockedLogInterval {
            return
        }
        lastTrafficLightBlockedLogTimeByWindowID[windowID] = now

        let effectiveCluster = HostTrafficLightProtectionPolicy.effectiveClusterSize(
            dynamicClusterSize: dynamicClusterSize
        )
        MirageLogger.host(
            "Blocked remote pointer event \(eventType) in traffic-light cluster for window \(windowID) at \(localPoint) within \(effectiveCluster)"
        )
    }
}

#endif
