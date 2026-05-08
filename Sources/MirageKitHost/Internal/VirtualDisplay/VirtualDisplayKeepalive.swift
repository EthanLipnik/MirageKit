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
import CoreVideo
import QuartzCore

@MainActor
final class VirtualDisplayKeepalive {
    private let displayID: CGDirectDisplayID
    private var spaceID: CGSSpaceID
    private var refreshRate: Double
    private var window: NSWindow?
    private var cadenceDriver: VirtualDisplayKeepaliveCadenceDriver?

    private let pixelSize: CGFloat = 6.0
    private let alphaLow: CGFloat = 0.035
    private let alphaHigh: CGFloat = 0.090

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
        startCadenceDriver(cadence: cadence)

        MirageLogger.host("Virtual display cadence driver started for display \(displayID) @ \(Int(cadence))Hz")
    }

    func stop() {
        stopCadenceDriver()
        window?.orderOut(nil)
        window = nil
        MirageLogger.host("Virtual display cadence driver stopped for display \(displayID)")
    }

    func updateBounds() {
        guard let window else { return }
        window.setFrame(windowFrame(), display: false)
    }

    func reconfigure(spaceID: CGSSpaceID, refreshRate: Double) {
        let previousCadence = resolvedCadence(for: self.refreshRate)
        self.spaceID = spaceID
        self.refreshRate = refreshRate
        if let window {
            let windowID = CGWindowID(window.windowNumber)
            CGSWindowSpaceBridge.moveWindowToSpace(windowID, spaceID: spaceID)
            updateBounds()
        }
        let cadence = resolvedCadence(for: refreshRate)
        guard cadence != previousCadence else { return }
        startCadenceDriver(cadence: cadence)
    }

    func restart() {
        let cadence = resolvedCadence(for: refreshRate)
        startCadenceDriver(cadence: cadence)
        MirageLogger.host("Virtual display cadence driver restarted for display \(displayID) @ \(Int(cadence))Hz")
    }

    private func startCadenceDriver(cadence: Double) {
        stopCadenceDriver()
        let driver = VirtualDisplayKeepaliveCadenceDriver(
            displayID: displayID,
            targetFPS: cadence
        ) { [weak self] tick in
            Task { @MainActor [weak self] in
                self?.advanceCadenceFrame(tick: tick)
            }
        }
        cadenceDriver = driver
        if !driver.start() {
            MirageLogger.host(
                "Virtual display cadence driver could not attach display link for display \(displayID); falling back to static keepalive"
            )
        }
    }

    private func stopCadenceDriver() {
        cadenceDriver?.stop()
        cadenceDriver = nil
    }

    private func advanceCadenceFrame(tick: UInt64) {
        guard let layer = window?.contentView?.layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let alpha = tick.isMultiple(of: 2) ? alphaLow : alphaHigh
        layer.backgroundColor = NSColor.black.withAlphaComponent(alpha).cgColor
        layer.setNeedsDisplay()
        CATransaction.commit()
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

    private func resolvedCadence(for refreshRate: Double) -> Double {
        refreshRate >= 120.0 ? 120.0 : 60.0
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

private final class VirtualDisplayKeepaliveCadenceDriver: @unchecked Sendable {
    private let displayID: CGDirectDisplayID
    private let targetFrameInterval: CFAbsoluteTime
    private let onTick: @Sendable (UInt64) -> Void
    private let stateLock = NSLock()

    private var displayLink: CVDisplayLink?
    private var isRunning = false
    private var tickCount: UInt64 = 0
    private var lastTickTime: CFAbsoluteTime = 0

    init(
        displayID: CGDirectDisplayID,
        targetFPS: Double,
        onTick: @escaping @Sendable (UInt64) -> Void
    ) {
        self.displayID = displayID
        self.targetFrameInterval = 1.0 / max(1.0, targetFPS)
        self.onTick = onTick

        var createdDisplayLink: CVDisplayLink?
        let creationStatus = CVDisplayLinkCreateWithCGDisplay(displayID, &createdDisplayLink)
        guard creationStatus == kCVReturnSuccess, let createdDisplayLink else {
            MirageLogger.error(
                .host,
                "Failed to create virtual-display cadence driver for display \(displayID): CVReturn=\(creationStatus)"
            )
            return
        }

        let callbackStatus = CVDisplayLinkSetOutputCallback(
            createdDisplayLink,
            { _, _, _, _, _, userInfo in
                guard let userInfo else { return kCVReturnError }
                let driver = Unmanaged<VirtualDisplayKeepaliveCadenceDriver>
                    .fromOpaque(userInfo)
                    .takeUnretainedValue()
                driver.handleDisplayTick()
                return kCVReturnSuccess
            },
            UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        )
        guard callbackStatus == kCVReturnSuccess else {
            MirageLogger.error(
                .host,
                "Failed to attach virtual-display cadence driver for display \(displayID): CVReturn=\(callbackStatus)"
            )
            return
        }

        displayLink = createdDisplayLink
    }

    deinit {
        stop()
    }

    func start() -> Bool {
        guard let displayLink else { return false }
        guard !isRunning else { return true }
        let status = CVDisplayLinkStart(displayLink)
        guard status == kCVReturnSuccess else {
            MirageLogger.error(
                .host,
                "Failed to start virtual-display cadence driver for display \(displayID): CVReturn=\(status)"
            )
            return false
        }
        isRunning = true
        return true
    }

    func stop() {
        guard let displayLink, isRunning else { return }
        CVDisplayLinkStop(displayLink)
        isRunning = false
    }

    private func handleDisplayTick() {
        let now = CFAbsoluteTimeGetCurrent()
        let tick: UInt64? = stateLock.withLock {
            if lastTickTime > 0, now - lastTickTime < targetFrameInterval * 0.55 {
                return nil
            }
            lastTickTime = now
            tickCount &+= 1
            return tickCount
        }
        guard let tick else { return }
        onTick(tick)
    }
}

@MainActor
final class VirtualDisplayKeepaliveController {
    static let shared = VirtualDisplayKeepaliveController()

    private var keepalives: [CGDirectDisplayID: VirtualDisplayKeepalive] = [:]

    func start(displayID: CGDirectDisplayID, spaceID: CGSSpaceID, refreshRate: Double) {
        if let existing = keepalives[displayID] {
            existing.reconfigure(spaceID: spaceID, refreshRate: refreshRate)
            existing.updateBounds()
            return
        }
        let keepalive = VirtualDisplayKeepalive(displayID: displayID, spaceID: spaceID, refreshRate: refreshRate)
        keepalive.start()
        keepalives[displayID] = keepalive
    }

    func restart(displayID: CGDirectDisplayID, spaceID: CGSSpaceID, refreshRate: Double) {
        if let existing = keepalives[displayID] {
            existing.reconfigure(spaceID: spaceID, refreshRate: refreshRate)
            existing.restart()
            return
        }
        start(displayID: displayID, spaceID: spaceID, refreshRate: refreshRate)
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
