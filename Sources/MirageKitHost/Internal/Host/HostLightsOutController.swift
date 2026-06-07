//
//  HostLightsOutController.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/5/26.
//
//  Blackout overlays, display dimming, and shortcut recovery for Lights Out mode.
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
import AppKit
import CoreGraphics
import Foundation

#if os(macOS)
@MainActor
final class HostLightsOutController {
    /// Duration that the local interaction message remains visible after user activity.
    static let messageDuration: Duration = .seconds(5)

    /// Gamma multiplier used to dim displays while Lights Out is active.
    static let dimmedGammaScale: CGGammaValue = 0.05

    /// Displays that should be covered and dimmed while Lights Out is active.
    enum Target: Equatable {
        /// Cover every online physical display while leaving Mirage virtual displays alone.
        case physicalDisplays

        /// Cover a specific set of CoreGraphics display IDs.
        case displayIDs(Set<CGDirectDisplayID>)
    }

    private var target: Target?
    private var overlays: [CGDirectDisplayID: HostLightsOutOverlay] = [:]
    var eventTap: CFMachPort?
    var eventTapSource: CFRunLoopSource?
    var messageHideTask: Task<Void, Never>?
    var screenChangeObserver: Any?
    var brightnessSnapshot: [CGDirectDisplayID: HostLightsOutGammaSnapshot] = [:]
    private let hotKeyRegistrar: any HostLightsOutHotKeyRegistering
    var virtualDisplayBackend: any MirageHostVirtualDisplayBackend
    let revealClock = ContinuousClock()
    var revealUntil: ContinuousClock.Instant?

    private let messageTitleText = "Streaming with Mirage"
    var onOverlayWindowsChanged: (@MainActor () -> Void)?
    var onEmergencyShortcut: (@MainActor () async -> Void)?

    /// Whether overlays, dimming, and recovery input handling are currently active.
    var isActive: Bool { target != nil }

    /// Window IDs for active overlays so capture code can exclude them.
    var overlayWindowIDs: [CGWindowID] {
        overlays.values.map { CGWindowID($0.window.windowNumber) }
    }

    /// Creates a controller using a Carbon hotkey registrar by default.
    init(
        hotKeyRegistrar: any HostLightsOutHotKeyRegistering = HostLightsOutHotKeyRegistrar(),
        virtualDisplayBackend: any MirageHostVirtualDisplayBackend = MacOSHostVirtualDisplayBackend()
    ) {
        self.hotKeyRegistrar = hotKeyRegistrar
        self.virtualDisplayBackend = virtualDisplayBackend
        self.hotKeyRegistrar.onTrigger = { [weak self] in
            self?.handleEmergencyShortcut()
        }
    }

    /// Activates, retargets, or deactivates Lights Out for the requested display scope.
    func updateTarget(
        _ newTarget: Target?,
        emergencyShortcut: MirageInput.MirageClientShortcutBinding
    ) -> Bool {
        guard let newTarget else {
            deactivate()
            return true
        }

        guard MirageHostLightsOutShortcut.validationError(for: emergencyShortcut) == nil else {
            MirageLogger.host("Lights Out skipped: invalid emergency shortcut \(emergencyShortcut.displayString)")
            deactivate()
            return false
        }

        guard hotKeyRegistrar.register(shortcut: emergencyShortcut) else {
            MirageLogger.host("Lights Out skipped: failed to register emergency shortcut \(emergencyShortcut.displayString)")
            deactivate()
            return false
        }

        target = newTarget
        let displayIDs = resolveDisplayIDs(for: newTarget)
        updateOverlays(for: displayIDs, emergencyShortcut: emergencyShortcut)
        updateBrightnessSnapshot(for: displayIDs)
        applyRevealState()
        ensureEventTapActive()
        ensureScreenChangeObserver()
        return true
    }

    /// Tears down overlays, restores brightness, and unregisters local recovery hooks.
    func deactivate() {
        target = nil
        messageHideTask?.cancel()
        messageHideTask = nil
        revealUntil = nil
        restoreBrightness()
        hotKeyRegistrar.unregister()
        removeEventTap()
        removeScreenChangeObserver()
        for overlay in overlays.values {
            overlay.close()
        }
        overlays.removeAll()
        brightnessSnapshot.removeAll()
        onOverlayWindowsChanged?()
    }

    private func handleEmergencyShortcut() {
        guard isActive else { return }
        MirageLogger.host("Lights Out: emergency shortcut triggered")
        Task { @MainActor [weak self] in
            await self?.onEmergencyShortcut?()
        }
    }

    func handleLocalInteraction(triggerMessage: Bool) {
        guard isActive else { return }
        let now = revealClock.now
        let wasRevealed = revealUntil.map { now < $0 } ?? false
        if triggerMessage {
            showMessage()
        }
        revealUntil = now + Self.messageDuration
        if !wasRevealed {
            restoreBrightness()
        }
        scheduleReDim()
    }

    // MARK: - Overlay Management

    private func updateOverlays(
        for displayIDs: Set<CGDirectDisplayID>,
        emergencyShortcut: MirageInput.MirageClientShortcutBinding
    ) {
        let previousWindowIDs = Set(overlayWindowIDs)
        let message = Self.overlayMessage(for: emergencyShortcut, title: messageTitleText)
        let removed = overlays.keys.filter { !displayIDs.contains($0) }
        for displayID in removed {
            overlays[displayID]?.close()
            overlays.removeValue(forKey: displayID)
        }

        for displayID in displayIDs {
            let frame = CGDisplayBounds(displayID)
            if let overlay = overlays[displayID] {
                overlay.updateFrame(frame)
                overlay.setMessage(message)
            } else {
                let overlay = HostLightsOutOverlay(frame: frame, message: message)
                overlays[displayID] = overlay
                MirageLogger.host("Lights Out: overlay created for display \(displayID) (sharingType=.none)")
            }
        }

        let updatedWindowIDs = Set(overlayWindowIDs)
        if previousWindowIDs != updatedWindowIDs {
            onOverlayWindowsChanged?()
        }
    }

    func showMessage() {
        for overlay in overlays.values {
            overlay.setMessageVisible(true)
        }
    }

    func hideMessage() {
        for overlay in overlays.values {
            overlay.setMessageVisible(false)
        }
    }

    private func scheduleReDim() {
        messageHideTask?.cancel()
        guard let revealUntil else { return }
        messageHideTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let deadline = revealUntil
            if deadline > revealClock.now {
                do {
                    try await Task.sleep(until: deadline, clock: revealClock)
                } catch {
                    return
                }
            }
            if Task.isCancelled { return }
            if self.revealUntil == deadline {
                self.revealUntil = nil
                hideMessage()
                dimDisplays()
            }
        }
    }

    /// Builds the overlay recovery message for the configured emergency shortcut.
    nonisolated static func overlayMessage(
        for emergencyShortcut: MirageInput.MirageClientShortcutBinding,
        title: String = "Streaming with Mirage"
    ) -> String {
        "\(title)\nPress \(emergencyShortcut.displayString) to Force Stop Streams"
    }

    private func resolveDisplayIDs(for target: Target) -> Set<CGDirectDisplayID> {
        switch target {
        case .physicalDisplays:
            physicalDisplayIDs()
        case let .displayIDs(displayIDs):
            displayIDs
        }
    }

    private func physicalDisplayIDs() -> Set<CGDirectDisplayID> {
        let displays = virtualDisplayBackend.onlineDisplayIDs()
        let physicalDisplays = displays.filter { !virtualDisplayBackend.isVirtualDisplay($0) }
        return Set(physicalDisplays)
    }

    // MARK: - Screen Change Handling

    private func ensureScreenChangeObserver() {
        guard screenChangeObserver == nil else { return }
        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleScreenChange()
            }
        }
    }

    private func removeScreenChangeObserver() {
        if let observer = screenChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        screenChangeObserver = nil
    }

    private func handleScreenChange() {
        guard let target,
              let emergencyShortcut = hotKeyRegistrar.registeredShortcut else {
            return
        }
        let displayIDs = resolveDisplayIDs(for: target)
        updateOverlays(for: displayIDs, emergencyShortcut: emergencyShortcut)
        updateBrightnessSnapshot(for: displayIDs)
        applyRevealState()
    }
}
#endif
