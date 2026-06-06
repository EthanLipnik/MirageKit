//
//  MirageHostInputController.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/21/26.
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
#if os(macOS)
import AppKit
import ApplicationServices
import Foundation

// MARK: - Private Accessibility API

/// Private but stable API to get CGWindowID from AXUIElement.
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ _: AXUIElement, _ _: UnsafeMutablePointer<CGWindowID>) -> AXError

enum HostKeyboardInjectionDomain: CaseIterable {
    case session
    case hid
}

/// Manages input event processing and CGEvent injection for remote input.
public final class MirageHostInputController: @unchecked Sendable {
    // MARK: - Dependencies

    /// Reference to window controller for AX lookups and resizing.
    public weak var windowController: MirageHostWindowController?

    /// Reference to host service for frame updates and virtual display queries.
    public weak var hostService: MirageHostService?

    // MARK: - Queue

    /// Serial queue for blocking Accessibility API operations.
    let accessibilityQueue = DispatchQueue(label: "com.mirage.accessibility", qos: .userInteractive)

    /// Cached mapping from stream frame to current OS-reported window frame.
    struct CachedInputWindowFrame {
        var streamFrame: CGRect
        var resolvedFrame: CGRect
        var sampledAt: CFAbsoluteTime
    }

    /// Cached traffic-light protection geometry for a sampled window frame.
    struct CachedTrafficLightClusterGeometry {
        var dynamicClusterSize: CGSize?
        var sampledWindowFrame: CGRect
        var sampledAt: CFAbsoluteTime
    }

    /// Recorded AXHidden values for traffic-light buttons hidden during direct streaming.
    struct HostTrafficLightVisibilitySnapshot {
        let closeHidden: Bool?
        let minimizeHidden: Bool?
        let zoomHidden: Bool?

        /// Whether at least one traffic-light button visibility value was recorded.
        var hasRecordedState: Bool {
            closeHidden != nil || minimizeHidden != nil || zoomHidden != nil
        }
    }

    var lastWindowActivationTime: CFAbsoluteTime?
    var lastActivatedWindowID: WindowID?
    var inputWindowFrameCacheByWindowID: [WindowID: CachedInputWindowFrame] = [:]
    var activeRelativeResizeTaskByWindowID: [WindowID: Task<Void, any Error>] = [:]
    var systemActionInFlightUntilByAction: [MirageInput.MirageHostSystemAction: CFAbsoluteTime] = [:]

    let inputWindowFrameRefreshInterval: CFAbsoluteTime = 0.05
    let inputWindowFrameCacheTTL: CFAbsoluteTime = 2.0
    let inputWindowFrameSourceTolerance: CGFloat = 6

    // MARK: - Traffic Light Protection State (accessed from accessibilityQueue only)

    var trafficLightClusterCacheByWindowID: [WindowID: CachedTrafficLightClusterGeometry] = [:]
    var trafficLightVisibilitySnapshotByWindowID: [WindowID: HostTrafficLightVisibilitySnapshot] = [:]
    var lastTrafficLightBlockedLogTimeByWindowID: [WindowID: CFAbsoluteTime] = [:]

    let trafficLightClusterCacheTTL: CFAbsoluteTime = 0.35
    let trafficLightBlockedLogInterval: CFAbsoluteTime = 1.0

    // MARK: - Tablet State (accessed from accessibilityQueue only)

    /// Tracks whether a synthetic tablet pointer is currently in proximity.
    var tabletProximityActive: Bool = false

    // MARK: - Modifier State Tracking (accessed from accessibilityQueue only)

    /// Track the last event time per modifier flag for individual staleness detection.
    var modifierLastEventTimes: [MirageInput.MirageModifierFlags: TimeInterval] = [:]

    /// Track the last sent modifier state (for detecting stuck modifiers).
    var lastSentModifiers: MirageInput.MirageModifierFlags = []

    /// Track which modifier key codes are currently held (for injecting keyUp on release).
    var heldModifierKeyCodes: Set<CGKeyCode> = []

    /// Last domain used to inject modifier transitions.
    var lastModifierInjectionDomain: HostKeyboardInjectionDomain = .session

    /// Timer to periodically check for stuck modifiers.
    var modifierResetTimer: DispatchSourceTimer?

    /// Last pointer-triggered check for host-observed modifiers Mirage is not holding.
    var lastPointerUnexpectedModifierCheckTime: TimeInterval = 0

    /// Maximum time modifiers can be held before being considered stuck.
    let modifierStuckTimeoutSeconds: TimeInterval = 0.5

    /// Poll interval for stuck modifier detection.
    let modifierResetPollIntervalSeconds: TimeInterval = 0.1

    /// Minimum spacing for pointer-triggered unexpected modifier checks.
    let pointerUnexpectedModifierCheckIntervalSeconds: TimeInterval = 0.25

    /// Mapping from modifier flags to their corresponding virtual key codes.
    static let modifierKeyCodes: [(flag: MirageInput.MirageModifierFlags, keyCode: CGKeyCode)] = [
        (.shift, 0x38),
        (.control, 0x3B),
        (.option, 0x3A),
        (.command, 0x37),
        (.capsLock, 0x39),
    ]

    /// Recovery key codes used to clear potentially-stuck modifier state.
    static let modifierRecoveryKeyCodes: [(flag: MirageInput.MirageModifierFlags, keyCodes: [CGKeyCode])] = [
        (.shift, [0x38, 0x3C]),
        (.control, [0x3B, 0x3E]),
        (.option, [0x3A, 0x3D]),
        (.command, [0x37, 0x36]),
        (.capsLock, [0x39]),
    ]

    /// Mapping from CGEventFlags to MirageInput.MirageModifierFlags for system state comparison.
    static let cgFlagToMirageFlag: [(cgFlag: CGEventFlags, mirageFlag: MirageInput.MirageModifierFlags)] = [
        (.maskShift, .shift),
        (.maskControl, .control),
        (.maskAlternate, .option),
        (.maskCommand, .command),
        (.maskAlphaShift, .capsLock),
    ]

    /// Returns the system event state source used for a keyboard injection domain.
    static func systemStateSource(for domain: HostKeyboardInjectionDomain) -> CGEventSourceStateID {
        switch domain {
        case .session:
            .combinedSessionState
        case .hid:
            .hidSystemState
        }
    }

    static let allModifierRecoveryKeyCodes = Set(modifierRecoveryKeyCodes.flatMap(\.keyCodes))

    /// Modifier key-code changes needed to move between two modifier states.
    struct ModifierTransitionPlan: Equatable {
        let pressed: [CGKeyCode]
        let released: [CGKeyCode]
    }

    /// Computes modifier key presses and releases for a requested modifier transition.
    static func modifierTransitionPlan(
        from previousModifiers: MirageInput.MirageModifierFlags,
        to nextModifiers: MirageInput.MirageModifierFlags
    )
    -> ModifierTransitionPlan {
        var newlyPressed: [CGKeyCode] = []
        var newlyReleased: [CGKeyCode] = []

        for (flag, keyCode) in modifierKeyCodes {
            let wasHeld = previousModifiers.contains(flag)
            let isHeld = nextModifiers.contains(flag)

            if isHeld, !wasHeld {
                newlyPressed.append(keyCode)
            } else if !isHeld, wasHeld {
                newlyReleased.append(keyCode)
            }
        }

        return ModifierTransitionPlan(pressed: newlyPressed, released: newlyReleased)
    }

    /// Fractional remainders for the direct injectScrollEvent path.
    var directScrollRemainderX: CGFloat = 0
    var directScrollRemainderY: CGFloat = 0

    /// Creates an input controller for host-side injection.
    /// - Parameters:
    ///   - windowController: Window controller for AX lookups and resizing.
    ///   - hostService: Host service for capture and stream updates.
    public init(
        windowController: MirageHostWindowController? = nil,
        hostService: MirageHostService? = nil
    ) {
        self.windowController = windowController
        self.hostService = hostService
    }

    // MARK: - Main Entry Point

    /// Handles input events from the host's input queue.
    /// - Parameters:
    ///   - event: The input event received from the client.
    ///   - window: The target window for the input event.
    public func handleInputEvent(_ event: MirageInput.MirageInputEvent, window: MirageMedia.MirageWindow) {
        handleInputEvent(event, window: window, deferredInjectionValidator: nil)
    }

    /// Handles an input event with an optional validator for deferred injection.
    func handleInputEvent(
        _ event: MirageInput.MirageInputEvent,
        window: MirageMedia.MirageWindow,
        deferredInjectionValidator: (@Sendable () -> Bool)?
    ) {
        if window.id == 0 {
            handleDesktopInputEvent(
                event,
                bounds: window.frame,
                deferredInjectionValidator: deferredInjectionValidator
            )
            return
        }

        switch event {
        case let .windowResize(resizeEvent):
            Task { @MainActor [weak self] in
                self?.handleWindowResize(window, resizeEvent: resizeEvent)
            }
        case let .relativeResize(event):
            Task { @MainActor [weak self] in
                self?.handleRelativeResize(window, event: event)
            }
        case let .pixelResize(event):
            Task { @MainActor [weak self] in
                self?.handlePixelResize(window, event: event)
            }
        default:
            handleInput(event, window: window, deferredInjectionValidator: deferredInjectionValidator)
        }
    }

    /// Returns whether a deferred input event should still be injected.
    func shouldProcessDeferredInput(
        _ deferredInjectionValidator: (@Sendable () -> Bool)?
    )
    -> Bool {
        deferredInjectionValidator?() ?? true
    }
}

#endif
