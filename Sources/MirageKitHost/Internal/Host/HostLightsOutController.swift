//
//  HostLightsOutController.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/5/26.
//
//  Blackout overlays and input blocking for Lights Out mode.
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

            let view = NSView(frame: CGRect(origin: .zero, size: frame.size))
            view.wantsLayer = true
            view.layer?.backgroundColor = NSColor.black.cgColor

            let label = NSTextField(labelWithString: message)
            label.translatesAutoresizingMaskIntoConstraints = false
            label.textColor = .white
            label.alignment = .center
            label.font = .systemFont(ofSize: 28, weight: .semibold)
            label.isHidden = true

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

        func setMessageVisible(_ visible: Bool) {
            messageLabel.isHidden = !visible
        }

        func close() {
            window.orderOut(nil)
            window.contentView = nil
        }
    }

    private struct DisplayGammaSnapshot {
        let red: [CGGammaValue]
        let green: [CGGammaValue]
        let blue: [CGGammaValue]
        let sampleCount: UInt32
    }

    private var target: Target?
    private var overlays: [CGDirectDisplayID: Overlay] = [:]
    private var eventTap: CFMachPort?
    private var eventTapSource: CFRunLoopSource?
    private var messageHideTask: Task<Void, Never>?
    private var screenChangeObserver: Any?
    private var brightnessSnapshot: [CGDirectDisplayID: DisplayGammaSnapshot] = [:]
    private let revealClock = ContinuousClock()
    private var revealUntil: ContinuousClock.Instant?

    private let messageText = "Streaming with Mirage"
    private let messageDuration: Duration = .seconds(5)
    private let dimmedGammaScale: CGGammaValue = 0.05

    var onOverlayWindowsChanged: (@MainActor () -> Void)?

    var isActive: Bool { target != nil }

    var overlayWindowIDs: [CGWindowID] {
        overlays.values.map { CGWindowID($0.window.windowNumber) }
    }

    func updateTarget(_ newTarget: Target?) {
        guard let newTarget else {
            deactivate()
            return
        }

        target = newTarget
        let displayIDs = resolveDisplayIDs(for: newTarget)
        updateOverlays(for: displayIDs)
        updateBrightnessSnapshot(for: displayIDs)
        applyRevealState()
        ensureEventTapActive()
        ensureScreenChangeObserver()
    }

    func deactivate() {
        target = nil
        messageHideTask?.cancel()
        messageHideTask = nil
        revealUntil = nil
        restoreBrightness()
        removeEventTap()
        removeScreenChangeObserver()
        for overlay in overlays.values {
            overlay.close()
        }
        overlays.removeAll()
        brightnessSnapshot.removeAll()
        onOverlayWindowsChanged?()
    }

    func handleLocalInteraction(triggerMessage: Bool) {
        guard isActive else { return }
        let now = revealClock.now
        let wasRevealed = revealUntil != nil && now < (revealUntil ?? now)
        if triggerMessage {
            showMessage()
        }
        revealUntil = now + messageDuration
        if !wasRevealed {
            restoreBrightness()
        }
        scheduleReDim()
    }

    // MARK: - Overlay Management

    private func updateOverlays(for displayIDs: Set<CGDirectDisplayID>) {
        let previousWindowIDs = Set(overlayWindowIDs)
        let removed = overlays.keys.filter { !displayIDs.contains($0) }
        for displayID in removed {
            overlays[displayID]?.close()
            overlays.removeValue(forKey: displayID)
        }

        for displayID in displayIDs {
            let frame = CGDisplayBounds(displayID)
            if let overlay = overlays[displayID] {
                overlay.updateFrame(frame)
            } else {
                let overlay = Overlay(displayID: displayID, frame: frame, message: messageText)
                overlays[displayID] = overlay
            }
        }

        let updatedWindowIDs = Set(overlayWindowIDs)
        if previousWindowIDs != updatedWindowIDs {
            onOverlayWindowsChanged?()
        }
    }

    private func showMessage() {
        for overlay in overlays.values {
            overlay.setMessageVisible(true)
        }
    }

    private func hideMessage() {
        for overlay in overlays.values {
            overlay.setMessageVisible(false)
        }
    }

    private func scheduleReDim() {
        messageHideTask?.cancel()
        guard let revealUntil else { return }
        messageHideTask = Task { [weak self] in
            guard let self else { return }
            let deadline = revealUntil
            if deadline > self.revealClock.now {
                do {
                    try await Task.sleep(until: deadline, clock: self.revealClock)
                } catch {
                    return
                }
            }
            if Task.isCancelled { return }
            if self.revealUntil == deadline {
                self.revealUntil = nil
                self.hideMessage()
                self.dimDisplays()
            }
        }
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

    // MARK: - Brightness

    private func updateBrightnessSnapshot(for displayIDs: Set<CGDirectDisplayID>) {
        let removed = brightnessSnapshot.keys.filter { !displayIDs.contains($0) }
        for displayID in removed {
            if let snapshot = brightnessSnapshot[displayID] {
                applyGamma(snapshot, scale: 1.0, displayID: displayID)
            }
            brightnessSnapshot.removeValue(forKey: displayID)
        }

        for displayID in displayIDs where brightnessSnapshot[displayID] == nil {
            if let snapshot = captureGammaSnapshot(for: displayID) {
                brightnessSnapshot[displayID] = snapshot
            }
        }
    }

    private func dimDisplays() {
        for (displayID, snapshot) in brightnessSnapshot {
            applyGamma(snapshot, scale: dimmedGammaScale, displayID: displayID)
        }
    }

    private func restoreBrightness() {
        for (displayID, snapshot) in brightnessSnapshot {
            applyGamma(snapshot, scale: 1.0, displayID: displayID)
        }
    }

    private func applyRevealState() {
        if let revealUntil, revealClock.now < revealUntil {
            showMessage()
            restoreBrightness()
        } else {
            hideMessage()
            dimDisplays()
        }
    }

    private func captureGammaSnapshot(for displayID: CGDirectDisplayID) -> DisplayGammaSnapshot? {
        let maxSamples: Int = 256
        var red = [CGGammaValue](repeating: 0, count: maxSamples)
        var green = [CGGammaValue](repeating: 0, count: maxSamples)
        var blue = [CGGammaValue](repeating: 0, count: maxSamples)
        var sampleCount: UInt32 = 0
        let result = CGGetDisplayTransferByTable(
            displayID,
            UInt32(maxSamples),
            &red,
            &green,
            &blue,
            &sampleCount
        )
        guard result == .success, sampleCount > 0 else { return nil }
        let count = Int(sampleCount)
        return DisplayGammaSnapshot(
            red: Array(red.prefix(count)),
            green: Array(green.prefix(count)),
            blue: Array(blue.prefix(count)),
            sampleCount: sampleCount
        )
    }

    private func applyGamma(_ snapshot: DisplayGammaSnapshot, scale: CGGammaValue, displayID: CGDirectDisplayID) {
        let clampedScale = max(0, min(1, scale))
        let red = snapshot.red.map { min(1, max(0, $0 * clampedScale)) }
        let green = snapshot.green.map { min(1, max(0, $0 * clampedScale)) }
        let blue = snapshot.blue.map { min(1, max(0, $0 * clampedScale)) }

        red.withUnsafeBufferPointer { redPtr in
            green.withUnsafeBufferPointer { greenPtr in
                blue.withUnsafeBufferPointer { bluePtr in
                    guard let redBase = redPtr.baseAddress,
                          let greenBase = greenPtr.baseAddress,
                          let blueBase = bluePtr.baseAddress else {
                        return
                    }
                    let result = CGSetDisplayTransferByTable(
                        displayID,
                        snapshot.sampleCount,
                        redBase,
                        greenBase,
                        blueBase
                    )
                    if result != .success {
                        MirageLogger.host("Lights Out: failed to apply display gamma (\(displayID), error \(result.rawValue))")
                    }
                }
            }
        }
    }

    // MARK: - Event Tap

    private func ensureEventTapActive() {
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

    private func removeEventTap() {
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
                if let tap = self.eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            }
            return Unmanaged.passUnretained(event)
        }

        if MirageInjectedEventTag.isInjected(event) {
            return Unmanaged.passUnretained(event)
        }

        if Self.shouldTriggerMessage(for: type) {
            Task { @MainActor [weak self] in
                self?.handleLocalInteraction(triggerMessage: true)
            }
        }

        return nil
    }

    private static func eventMask() -> CGEventMask {
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

    private nonisolated static func shouldTriggerMessage(for type: CGEventType) -> Bool {
        switch type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel, .keyDown, .keyUp, .flagsChanged:
            return true
        default:
            return false
        }
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
        guard let target else { return }
        let displayIDs = resolveDisplayIDs(for: target)
        updateOverlays(for: displayIDs)
        updateBrightnessSnapshot(for: displayIDs)
        applyRevealState()
    }
}
#endif
