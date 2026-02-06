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

/// Manages input event processing, batching, scroll smoothing, and injection for remote input.
///
/// Handles mouse batching, scroll smoothing (120Hz), and CGEvent injection on macOS hosts.
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

    struct PointerLerpContext {
        var type: CGEventType
        var event: MirageMouseEvent
        var frame: CGRect
        var windowID: WindowID
        var app: MirageApplication?
        var isDesktop: Bool
    }

    // MARK: - Pointer Lerp State (accessed from accessibilityQueue only)

    var pointerContext: PointerLerpContext?
    var pointerCurrentLocation: CGPoint?
    var pointerTargetLocation: CGPoint?
    var pointerLastInputTime: TimeInterval = 0
    var pointerLastSendTime: TimeInterval = 0

    var pointerLerpTimer: DispatchSourceTimer?

    let pointerOutputIntervalMs: UInt64 = 8
    let pointerLerpTimeConstant: TimeInterval = 0.025
    let pointerStopDelay: TimeInterval = 0.05
    let pointerSnapThreshold: CGFloat = 0.0005

    // MARK: - Modifier State Tracking (accessed from accessibilityQueue only)

    /// Track the last event time per modifier flag for individual staleness detection.
    var modifierLastEventTimes: [MirageModifierFlags: TimeInterval] = [:]

    /// Track the last sent modifier state (for detecting stuck modifiers).
    var lastSentModifiers: MirageModifierFlags = []

    /// Track which modifier key codes are currently held (for injecting keyUp on release).
    var heldModifierKeyCodes: Set<CGKeyCode> = []

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

    /// Mapping from CGEventFlags to MirageModifierFlags for system state comparison.
    static let cgFlagToMirageFlag: [(cgFlag: CGEventFlags, mirageFlag: MirageModifierFlags)] = [
        (.maskShift, .shift),
        (.maskControl, .control),
        (.maskAlternate, .option),
        (.maskCommand, .command),
        (.maskAlphaShift, .capsLock),
    ]

    // MARK: - Scroll Rate Smoothing State (accessed from accessibilityQueue only)

    /// Smoothed scroll rate in pixels per second.
    var scrollRateX: CGFloat = 0
    var scrollRateY: CGFloat = 0
    var scrollTargetRateX: CGFloat = 0
    var scrollTargetRateY: CGFloat = 0

    /// Timestamp of last scroll input.
    var lastScrollInputTime: TimeInterval = 0
    var lastScrollOutputTime: TimeInterval = 0

    /// Fractional remainders to preserve precision.
    var scrollRemainderX: CGFloat = 0
    var scrollRemainderY: CGFloat = 0

    /// Context for scroll injection.
    var scrollContext: (
        frame: CGRect,
        app: MirageApplication?,
        location: CGPoint?,
        modifiers: MirageModifierFlags,
        isPrecise: Bool
    )?

    /// Timer for smooth scroll output (120Hz).
    var scrollOutputTimer: DispatchSourceTimer?

    /// Scroll smoothing constants.
    let scrollLerpTimeConstant: TimeInterval = 0.025
    let scrollRateDecay: CGFloat = 0.85
    let scrollDecayDelay: TimeInterval = 0.03
    let scrollRateThreshold: CGFloat = 10.0
    let scrollOutputIntervalMs: UInt64 = 8

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
