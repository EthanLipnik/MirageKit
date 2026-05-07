//
//  HostLightsOutController.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/5/26.
//
//  Blackout overlays and shortcut recovery for Lights Out mode.
//

import AppKit
import CoreGraphics
import Foundation
import MirageKit

#if os(macOS)
@MainActor
final class HostLightsOutController {
    enum Target: Equatable {
        case physicalDisplays
        case displayIDs(Set<CGDirectDisplayID>)

        static func == (lhs: Target, rhs: Target) -> Bool {
            switch (lhs, rhs) {
            case (.physicalDisplays, .physicalDisplays):
                true
            case let (.displayIDs(left), .displayIDs(right)):
                left == right
            default:
                false
            }
        }
    }

    @MainActor
    private final class Overlay {
        let displayID: CGDirectDisplayID
        let window: NSWindow
        let messageLabel: NSTextField

        init(displayID: CGDirectDisplayID, frame: CGRect, message: String) {
            self.displayID = displayID

            let window = NSWindow(
                contentRect: frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.animationBehavior = .none
            window.isOpaque = true
            window.backgroundColor = .black
            window.hasShadow = false
            window.level = .screenSaver
            window.ignoresMouseEvents = true
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.sharingType = .none

            let view = NSView(frame: CGRect(origin: .zero, size: frame.size))
            view.wantsLayer = true
            view.layer?.backgroundColor = NSColor.black.cgColor

            let label = NSTextField(labelWithString: message)
            label.translatesAutoresizingMaskIntoConstraints = false
            label.textColor = .white
            label.alignment = .center
            label.font = .systemFont(ofSize: 28, weight: .semibold)
            label.maximumNumberOfLines = 2
            label.lineBreakMode = .byWordWrapping
            label.isHidden = false

            view.addSubview(label)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            ])

            window.contentView = view
            window.orderFrontRegardless()

            self.window = window
            self.messageLabel = label
        }

        func updateFrame(_ frame: CGRect) {
            window.setFrame(frame, display: true, animate: false)
            if let view = window.contentView {
                view.frame = CGRect(origin: .zero, size: frame.size)
            }
        }

        func setMessage(_ message: String) {
            messageLabel.stringValue = message
        }

        func close() {
            window.orderOut(nil)
            window.contentView = nil
        }
    }

    private var target: Target?
    private var overlays: [CGDirectDisplayID: Overlay] = [:]
    private var screenChangeObserver: Any?
    private let hotKeyRegistrar: any HostLightsOutHotKeyRegistering

    private let messageTitleText = "Streaming with Mirage"

    var onOverlayWindowsChanged: (@MainActor () -> Void)?
    var onEmergencyShortcut: (@MainActor () async -> Void)?

    var isActive: Bool { target != nil }

    var overlayWindowIDs: [CGWindowID] {
        overlays.values.map { CGWindowID($0.window.windowNumber) }
    }

    init(hotKeyRegistrar: any HostLightsOutHotKeyRegistering = HostLightsOutHotKeyRegistrar()) {
        self.hotKeyRegistrar = hotKeyRegistrar
        self.hotKeyRegistrar.onTrigger = { [weak self] in
            self?.handleEmergencyShortcut()
        }
    }

    @discardableResult
    func updateTarget(
        _ newTarget: Target?,
        emergencyShortcut: MirageClientShortcutBinding
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
        ensureScreenChangeObserver()
        return true
    }

    func deactivate() {
        target = nil
        hotKeyRegistrar.unregister()
        removeScreenChangeObserver()
        for overlay in overlays.values {
            overlay.close()
        }
        overlays.removeAll()
        onOverlayWindowsChanged?()
    }

    private func handleEmergencyShortcut() {
        guard isActive else { return }
        MirageLogger.host("Lights Out: emergency shortcut triggered")
        Task { @MainActor [weak self] in
            await self?.onEmergencyShortcut?()
        }
    }

    // MARK: - Overlay Management

    private func updateOverlays(
        for displayIDs: Set<CGDirectDisplayID>,
        emergencyShortcut: MirageClientShortcutBinding
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
                let overlay = Overlay(displayID: displayID, frame: frame, message: message)
                overlays[displayID] = overlay
                MirageLogger.host("Lights Out: overlay created for display \(displayID) (sharingType=.none)")
            }
        }

        let updatedWindowIDs = Set(overlayWindowIDs)
        if previousWindowIDs != updatedWindowIDs {
            onOverlayWindowsChanged?()
        }
    }

    nonisolated static func overlayMessage(
        for emergencyShortcut: MirageClientShortcutBinding,
        title: String = "Streaming with Mirage"
    ) -> String {
        "\(title)\nPress \(emergencyShortcut.displayString) to Force Stop Streams"
    }

    private func resolveDisplayIDs(for target: Target) -> Set<CGDirectDisplayID> {
        switch target {
        case .physicalDisplays:
            return physicalDisplayIDs()
        case let .displayIDs(displayIDs):
            return displayIDs
        }
    }

    private func physicalDisplayIDs() -> Set<CGDirectDisplayID> {
        var displayCount: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &displayCount)
        guard displayCount > 0 else { return [] }

        var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        CGGetOnlineDisplayList(displayCount, &displays, &displayCount)

        let physicalDisplays = displays.filter { !CGVirtualDisplayBridge.isVirtualDisplay($0) }
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
    }
}
#endif
