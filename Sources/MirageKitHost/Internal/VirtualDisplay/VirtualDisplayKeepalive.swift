//
//  VirtualDisplayKeepalive.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/26/26.
//
//  Keepalive window for virtual display compositor cadence.
//

import MirageKit
#if os(macOS)
import AppKit
import CoreGraphics
import QuartzCore

@MainActor
final class VirtualDisplayKeepalive {
    private let displayID: CGDirectDisplayID
    private let spaceID: CGSSpaceID
    private let refreshRate: Double
    private var window: NSWindow?
    private let animationKey = "com.mirage.keepalive.pulse"

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
        startAnimation(cadence: cadence)

        MirageLogger.host("Virtual display keepalive started for display \(displayID) @ \(Int(cadence))Hz")
    }

    func stop() {
        stopAnimation()
        window?.orderOut(nil)
        window = nil
        MirageLogger.host("Virtual display keepalive stopped for display \(displayID)")
    }

    func updateBounds() {
        guard let window else { return }
        window.setFrame(windowFrame(), display: false)
    }

    private func startAnimation(cadence: Double) {
        guard let layer = window?.contentView?.layer else { return }
        layer.removeAnimation(forKey: animationKey)

        let fromColor = NSColor.black.withAlphaComponent(alphaLow).cgColor
        let toColor = NSColor.black.withAlphaComponent(alphaHigh).cgColor

        let animation = CABasicAnimation(keyPath: "backgroundColor")
        animation.fromValue = fromColor
        animation.toValue = toColor
        animation.duration = 1.0 / max(1.0, cadence)
        animation.autoreverses = true
        animation.repeatCount = .greatestFiniteMagnitude
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        animation.isRemovedOnCompletion = false

        layer.backgroundColor = toColor
        layer.add(animation, forKey: animationKey)
    }

    private func stopAnimation() {
        window?.contentView?.layer?.removeAnimation(forKey: animationKey)
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
