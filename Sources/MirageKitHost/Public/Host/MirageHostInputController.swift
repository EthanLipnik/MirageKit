//
//  MirageHostInputController.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/21/26.
//

import MirageKit
#if os(macOS)
import AppKit
import ApplicationServices
import Foundation

// MARK: - Private Accessibility API

/// Private but stable API to get CGWindowID from AXUIElement.
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

enum HostKeyboardInjectionDomain: CaseIterable, Sendable {
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

    /// Optional permission manager for accessibility checks.
    public var permissionManager: MirageAccessibilityPermissionManager?

    // MARK: - Queue

    /// Serial queue for blocking Accessibility API operations.
    let accessibilityQueue = DispatchQueue(label: "com.mirage.accessibility", qos: .userInteractive)

    struct CachedInputWindowFrame {
        var streamFrame: CGRect
        var resolvedFrame: CGRect
        var sampledAt: CFAbsoluteTime
    }

    struct CachedTrafficLightClusterGeometry {
        var dynamicClusterSize: CGSize?
        var sampledWindowFrame: CGRect
        var sampledAt: CFAbsoluteTime
    }

    struct HostTrafficLightVisibilitySnapshot {
        let closeHidden: Bool?
        let minimizeHidden: Bool?
        let zoomHidden: Bool?

        var hasRecordedState: Bool {
            closeHidden != nil || minimizeHidden != nil || zoomHidden != nil
        }
    }

    var lastWindowActivationTime: CFAbsoluteTime?
    var lastActivatedWindowID: WindowID?
    var inputWindowFrameCacheByWindowID: [WindowID: CachedInputWindowFrame] = [:]
    var activeRelativeResizeTaskByWindowID: [WindowID: Task<Void, any Error>] = [:]

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
    var modifierLastEventTimes: [MirageModifierFlags: TimeInterval] = [:]

    /// Track the last sent modifier state (for detecting stuck modifiers).
    var lastSentModifiers: MirageModifierFlags = []

    /// Track which modifier key codes are currently held (for injecting keyUp on release).
    var heldModifierKeyCodes: Set<CGKeyCode> = []

    /// Last domain used to inject modifier transitions.
    var lastModifierInjectionDomain: HostKeyboardInjectionDomain = .session

    /// Timer to periodically check for stuck modifiers.
    var modifierResetTimer: DispatchSourceTimer?

    /// Maximum time modifiers can be held before being considered stuck.
    let modifierStuckTimeoutSeconds: TimeInterval = 0.5

    /// Poll interval for stuck modifier detection.
    let modifierResetPollIntervalSeconds: TimeInterval = 0.1

    /// Mapping from modifier flags to their corresponding virtual key codes.
    static let modifierKeyCodes: [(flag: MirageModifierFlags, keyCode: CGKeyCode)] = [
        (.shift, 0x38),
        (.control, 0x3B),
        (.option, 0x3A),
        (.command, 0x37),
        (.capsLock, 0x39),
    ]

    /// Recovery key codes used to clear potentially-stuck modifier state.
    static let modifierRecoveryKeyCodes: [(flag: MirageModifierFlags, keyCodes: [CGKeyCode])] = [
        (.shift, [0x38, 0x3C]),
        (.control, [0x3B, 0x3E]),
        (.option, [0x3A, 0x3D]),
        (.command, [0x37, 0x36]),
        (.capsLock, [0x39]),
    ]

    /// Mapping from CGEventFlags to MirageModifierFlags for system state comparison.
    static let cgFlagToMirageFlag: [(cgFlag: CGEventFlags, mirageFlag: MirageModifierFlags)] = [
        (.maskShift, .shift),
        (.maskControl, .control),
        (.maskAlternate, .option),
        (.maskCommand, .command),
        (.maskAlphaShift, .capsLock),
    ]

    static func systemStateSource(for domain: HostKeyboardInjectionDomain) -> CGEventSourceStateID {
        switch domain {
        case .session:
            .combinedSessionState
        case .hid:
            .hidSystemState
        }
    }

    static func recoveryKeyCodes(for flag: MirageModifierFlags) -> [CGKeyCode] {
        modifierRecoveryKeyCodes.first(where: { $0.flag == flag })?.keyCodes ?? []
    }

    static var allModifierRecoveryKeyCodes: Set<CGKeyCode> {
        Set(modifierRecoveryKeyCodes.flatMap(\.keyCodes))
    }

    struct ModifierTransitionPlan: Equatable {
        let pressed: [CGKeyCode]
        let released: [CGKeyCode]
    }

    static func modifierTransitionPlan(
        from previousModifiers: MirageModifierFlags,
        to nextModifiers: MirageModifierFlags
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

    // MARK: - Gesture Translation State (accessed from accessibilityQueue only)

    /// Accumulated magnification for command+scroll translation.
    var magnifyAccumulator: CGFloat = 0

    /// Threshold before triggering a zoom scroll event.
    let magnifyScrollThreshold: CGFloat = 0.02

    /// Accumulated rotation for option+scroll translation.
    var rotationAccumulator: CGFloat = 0

    /// Threshold before triggering a rotation scroll event.
    let rotationScrollThreshold: CGFloat = 2.0

    /// Creates an input controller for host-side injection.
    /// - Parameters:
    ///   - windowController: Window controller for AX lookups and resizing.
    ///   - hostService: Host service for capture and stream updates.
    ///   - permissionManager: Optional accessibility permission manager.
    public init(
        windowController: MirageHostWindowController? = nil,
        hostService: MirageHostService? = nil,
        permissionManager: MirageAccessibilityPermissionManager? = nil
    ) {
        self.windowController = windowController
        self.hostService = hostService
        self.permissionManager = permissionManager
    }

    // MARK: - Main Entry Point

    /// Handle input events from the host's input queue.
    /// - Parameters:
    ///   - event: The input event received from the client.
    ///   - window: The target window for the input event.
    public func handleInputEvent(_ event: MirageInputEvent, window: MirageWindow) {
        if window.id == 0 {
            handleDesktopInputEvent(event, bounds: window.frame)
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
            handleInput(event, window: window)
        }
    }
}

#endif
