//
//  HostLightsOutController+EventTap.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/13/26.
//
//  Local input interception for host Lights Out mode.
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
extension HostLightsOutController {
    // MARK: - Local Interaction

    func ensureEventTapActive() {
        guard eventTap == nil else { return }

        let mask = Self.eventMask()
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let controller = Unmanaged<HostLightsOutController>.fromOpaque(refcon).takeUnretainedValue()
            return controller.handleEventTap(type: type, event: event)
        }

        let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )

        guard let tap else {
            MirageLogger.error(.host, "Lights Out: failed to create event tap")
            return
        }

        eventTap = tap
        eventTapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let eventTapSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), eventTapSource, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
        MirageLogger.host("Lights Out: event tap enabled")
    }

    func removeEventTap() {
        guard let tap = eventTap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let eventTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), eventTapSource, .commonModes)
        }
        eventTapSource = nil
        eventTap = nil
        MirageLogger.host("Lights Out: event tap disabled")
    }

    private nonisolated func handleEventTap(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            }
            return Unmanaged.passUnretained(event)
        }

        if MirageInjectedEventTag.isInjected(event) {
            return Unmanaged.passUnretained(event)
        }

        if Self.shouldTriggerRevealMessage(for: type) {
            Task { @MainActor [weak self] in
                self?.handleLocalInteraction(triggerMessage: true)
            }
        }

        return nil
    }

    static func eventMask() -> CGEventMask {
        let types: [CGEventType] = [
            .leftMouseDown,
            .leftMouseUp,
            .rightMouseDown,
            .rightMouseUp,
            .otherMouseDown,
            .otherMouseUp,
            .leftMouseDragged,
            .rightMouseDragged,
            .otherMouseDragged,
            .mouseMoved,
            .scrollWheel,
            .keyDown,
            .keyUp,
            .flagsChanged,
        ]

        return types.reduce(CGEventMask(0)) { mask, type in
            mask | CGEventMask(1 << type.rawValue)
        }
    }

    /// Returns whether a local event should reveal the recovery shortcut message.
    nonisolated static func shouldTriggerRevealMessage(for type: CGEventType) -> Bool {
        switch type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel, .keyDown, .keyUp, .flagsChanged:
            true
        default:
            false
        }
    }
}
#endif
