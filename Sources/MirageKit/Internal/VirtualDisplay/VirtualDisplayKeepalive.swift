//
//  VirtualDisplayKeepalive.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/26/26.
//
//  Keepalive window for virtual display compositor cadence.
//

#if os(macOS)
import AppKit
import CoreGraphics

@MainActor
final class VirtualDisplayKeepalive {
    private let displayID: CGDirectDisplayID
    private let spaceID: CGSSpaceID
    private let refreshRate: Double
    private var window: NSWindow?
    private var timer: Timer?
    private var toggle = false

    private let pixelSize: CGFloat = 2.0
    private let alphaLow: CGFloat = 0.01
    private let alphaHigh: CGFloat = 0.02

    init(displayID: CGDirectDisplayID, spaceID: CGSSpaceID, refreshRate: Double) {
        self.displayID = displayID
        self.spaceID = spaceID
        self.refreshRate = refreshRate
    }

    func start() {
        guard window == nil else { return }

        let window = makeWindow()
        let windowID = CGWindowID(window.windowNumber)
        CGSWindowSpaceBridge.moveWindowToSpace(windowID, spaceID: spaceID)
        window.orderFrontRegardless()
        self.window = window

        let cadence = refreshRate >= 120.0 ? 120.0 : 60.0
        let interval = 1.0 / max(1.0, cadence)
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
        timer.tolerance = interval * 0.25
        self.timer = timer

        MirageLogger.host("Virtual display keepalive started for display \(displayID) @ \(Int(cadence))Hz")
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        window?.orderOut(nil)
        window = nil
        MirageLogger.host("Virtual display keepalive stopped for display \(displayID)")
    }

    func updateBounds() {
        guard let window else { return }
        window.setFrame(windowFrame(), display: false)
    }

    private func tick() {
        guard let layer = window?.contentView?.layer else { return }
        toggle.toggle()
        let alpha = toggle ? alphaLow : alphaHigh
        layer.backgroundColor = NSColor.black.withAlphaComponent(alpha).cgColor
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: windowFrame(),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .normal
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.stationary, .ignoresCycle, .fullScreenAuxiliary]

        let view = NSView(frame: CGRect(origin: .zero, size: window.frame.size))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.withAlphaComponent(alphaLow).cgColor
        window.contentView = view

        return window
    }

    private func windowFrame() -> CGRect {
        let bounds = CGDisplayBounds(displayID)
        let origin = CGPoint(
            x: bounds.maxX - pixelSize - 1.0,
            y: bounds.minY + 1.0
        )
        return CGRect(origin: origin, size: CGSize(width: pixelSize, height: pixelSize))
    }
}

@MainActor
final class VirtualDisplayKeepaliveController {
    static let shared = VirtualDisplayKeepaliveController()

    private var keepalives: [CGDirectDisplayID: VirtualDisplayKeepalive] = [:]

    func start(displayID: CGDirectDisplayID, spaceID: CGSSpaceID, refreshRate: Double) {
        if let existing = keepalives[displayID] {
            existing.updateBounds()
            return
        }
        let keepalive = VirtualDisplayKeepalive(displayID: displayID, spaceID: spaceID, refreshRate: refreshRate)
        keepalive.start()
        keepalives[displayID] = keepalive
    }

    func update(displayID: CGDirectDisplayID) {
        keepalives[displayID]?.updateBounds()
    }

    func stop(displayID: CGDirectDisplayID) {
        guard let keepalive = keepalives.removeValue(forKey: displayID) else { return }
        keepalive.stop()
    }

    func stopAll() {
        let entries = keepalives
        keepalives.removeAll()
        for keepalive in entries.values {
            keepalive.stop()
        }
    }
}

#endif
