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

/// Maintains compositor activity for a virtual display by animating a tiny transparent window.
@MainActor
final class VirtualDisplayKeepalive {
    enum Strength: Sendable, Equatable {
        case normal
        case strengthened
    }

    /// Size of the tiny keepalive pixel drawn at the display edge.
    private static func pixelSize(for strength: Strength) -> CGFloat {
        switch strength {
        case .normal:
            6.0
        case .strengthened:
            18.0
        }
    }

    /// Lower alpha in the alternating keepalive cadence.
    private static func alphaLow(for strength: Strength) -> CGFloat {
        switch strength {
        case .normal:
            0.035
        case .strengthened:
            0.075
        }
    }

    /// Higher alpha in the alternating keepalive cadence.
    private static func alphaHigh(for strength: Strength) -> CGFloat {
        switch strength {
        case .normal:
            0.090
        case .strengthened:
            0.160
        }
    }

    private let displayID: CGDirectDisplayID
    private var spaceID: CGSSpaceID
    private var refreshRate: Double
    private var strength: Strength = .normal
    private var window: NSWindow?
    private var cadenceDriver: VirtualDisplayKeepaliveCadenceDriver?
    private var appliedDirtyFrameCount: UInt64 = 0
    private var appliedMetalDirtyFrameCount: UInt64 = 0
    private var appliedStatsWindowStart: CFAbsoluteTime = 0

    /// Creates a keepalive for a display in the target CoreGraphics space.
    init(displayID: CGDirectDisplayID, spaceID: CGSSpaceID, refreshRate: Double) {
        self.displayID = displayID
        self.spaceID = spaceID
        self.refreshRate = refreshRate
    }

    /// Creates the keepalive window, moves it to the display space, and starts cadence animation.
    func start() {
        guard window == nil else { return }

        let window = makeWindow()
        let windowID = CGWindowID(window.windowNumber)
        CGSWindowSpaceBridge.moveWindowToSpace(windowID, spaceID: spaceID)
        window.orderFrontRegardless()
        self.window = window

        let cadence = resolvedCadence(for: refreshRate)
        startCadenceDriver(cadence: cadence)

        MirageLogger.host(
            "Virtual display cadence driver started for display \(displayID) @ \(Int(cadence))Hz strength=\(strength)"
        )
    }

    /// Stops cadence animation and hides the keepalive window.
    func stop() {
        stopCadenceDriver()
        window?.orderOut(nil)
        window = nil
        MirageLogger.host("Virtual display cadence driver stopped for display \(displayID)")
    }

    /// Repositions the keepalive window after display bounds change.
    func updateBounds() {
        guard let window else { return }
        window.setFrame(windowFrame(), display: false)
    }

    /// Moves the keepalive into a new space and updates cadence if the display mode changed.
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

    /// Restarts cadence animation for an existing keepalive window.
    func restart() {
        let cadence = resolvedCadence(for: refreshRate)
        startCadenceDriver(cadence: cadence)
        MirageLogger.host(
            "Virtual display cadence driver restarted for display \(displayID) @ \(Int(cadence))Hz strength=\(strength)"
        )
    }

    /// Strengthens the dirty surface and restarts cadence animation.
    func restart(strength: Strength) {
        self.strength = strength
        updateBounds()
        restart()
    }

    /// Replaces the current cadence driver with one targeting `cadence`.
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

    /// Stops and releases the active display-link driver.
    private func stopCadenceDriver() {
        cadenceDriver?.stop()
        cadenceDriver = nil
    }

    /// Alternates the keepalive pixel alpha so the compositor has visible frame work.
    private func advanceCadenceFrame(tick: UInt64) {
        guard let contentView = window?.contentView as? VirtualDisplayKeepaliveContentView else { return }
        let usedMetal = contentView.drawDirtyFrame(
            tick: tick,
            alphaLow: Self.alphaLow(for: strength),
            alphaHigh: Self.alphaHigh(for: strength)
        )
        recordAppliedDirtyFrame(usedMetal: usedMetal)
    }

    private func recordAppliedDirtyFrame(usedMetal: Bool) {
        let now = CFAbsoluteTimeGetCurrent()
        if appliedStatsWindowStart <= 0 {
            appliedStatsWindowStart = now
        }
        appliedDirtyFrameCount &+= 1
        if usedMetal {
            appliedMetalDirtyFrameCount &+= 1
        }
        let elapsed = now - appliedStatsWindowStart
        guard elapsed >= 1.0 else { return }
        let appliedFPS = Double(appliedDirtyFrameCount) / max(0.001, elapsed)
        let metalFPS = Double(appliedMetalDirtyFrameCount) / max(0.001, elapsed)
        MirageLogger.host(
            "event=virtual_display_keepalive_dirty_frames display=\(displayID) " +
                "applied=\(appliedDirtyFrameCount) metal=\(appliedMetalDirtyFrameCount) " +
                "appliedFPS=\(appliedFPS.formatted(.number.precision(.fractionLength(1)))) " +
                "metalFPS=\(metalFPS.formatted(.number.precision(.fractionLength(1)))) " +
                "strength=\(strength)"
        )
        appliedDirtyFrameCount = 0
        appliedMetalDirtyFrameCount = 0
        appliedStatsWindowStart = now
    }

    /// Builds the tiny transparent window used to keep the virtual display refreshing.
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

        let view = VirtualDisplayKeepaliveContentView(
            frame: CGRect(origin: .zero, size: window.frame.size),
            alpha: Self.alphaLow(for: strength)
        )
        window.contentView = view

        return window
    }

    /// Uses 120 Hz only for high-refresh displays; otherwise keeps a 60 Hz cadence.
    private func resolvedCadence(for refreshRate: Double) -> Double {
        refreshRate >= 120.0 ? 120.0 : 60.0
    }

    /// Positions the keepalive pixel just inside the display bounds.
    private func windowFrame() -> CGRect {
        let bounds = CGDisplayBounds(displayID)
        let pixelSize = Self.pixelSize(for: strength)
        let origin = CGPoint(
            x: bounds.maxX - pixelSize - 1.0,
            y: bounds.minY + 1.0
        )
        return CGRect(origin: origin, size: CGSize(width: pixelSize, height: pixelSize))
    }
}

/// Thin CVDisplayLink wrapper that throttles ticks to the target frame interval.
private final class VirtualDisplayKeepaliveCadenceDriver: @unchecked Sendable {
    private let displayID: CGDirectDisplayID
    private let targetFrameInterval: CFAbsoluteTime
    private let onTick: @Sendable (UInt64) -> Void
    private let stateLock = NSLock()

    private var displayLink: CVDisplayLink?
    private var isRunning = false
    private var tickCount: UInt64 = 0
    private var lastTickTime: CFAbsoluteTime = 0
    private var rawTickCountWindow: UInt64 = 0
    private var emittedTickCountWindow: UInt64 = 0
    private var statsWindowStart: CFAbsoluteTime = 0

    /// Creates a display link for `displayID` and calls `onTick` at roughly `targetFPS`.
    init(
        displayID: CGDirectDisplayID,
        targetFPS: Double,
        onTick: @escaping @Sendable (UInt64) -> Void
    ) {
        self.displayID = displayID
        targetFrameInterval = 1.0 / max(1.0, targetFPS)
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

    /// Stops the display link before release.
    deinit {
        stop()
    }

    /// Starts the display link if it was created successfully.
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

    /// Stops the display link if it is currently running.
    func stop() {
        guard let displayLink, isRunning else { return }
        CVDisplayLinkStop(displayLink)
        isRunning = false
    }

    /// Handles raw display-link callbacks and suppresses callbacks above the target cadence.
    private func handleDisplayTick() {
        let now = CFAbsoluteTimeGetCurrent()
        let result: (tick: UInt64?, stats: (raw: UInt64, emitted: UInt64, elapsed: CFAbsoluteTime)?) =
            stateLock.withLock {
                if statsWindowStart <= 0 {
                    statsWindowStart = now
                }
                rawTickCountWindow &+= 1
                if lastTickTime > 0, now - lastTickTime < targetFrameInterval * 0.55 {
                    return (nil, consumeStatsIfNeeded(now: now))
                }
                lastTickTime = now
                tickCount &+= 1
                emittedTickCountWindow &+= 1
                return (tickCount, consumeStatsIfNeeded(now: now))
            }
        if let stats = result.stats {
            logDriverStats(stats)
        }
        guard let tick = result.tick else { return }
        onTick(tick)
    }

    private func consumeStatsIfNeeded(
        now: CFAbsoluteTime
    ) -> (raw: UInt64, emitted: UInt64, elapsed: CFAbsoluteTime)? {
        let elapsed = now - statsWindowStart
        guard elapsed >= 1.0 else { return nil }
        let stats: (raw: UInt64, emitted: UInt64, elapsed: CFAbsoluteTime) = (
            rawTickCountWindow,
            emittedTickCountWindow,
            elapsed
        )
        rawTickCountWindow = 0
        emittedTickCountWindow = 0
        statsWindowStart = now
        return stats
    }

    private func logDriverStats(_ stats: (raw: UInt64, emitted: UInt64, elapsed: CFAbsoluteTime)) {
        let elapsed = max(0.001, stats.elapsed)
        let rawFPS = Double(stats.raw) / elapsed
        let emittedFPS = Double(stats.emitted) / elapsed
        MirageLogger.host(
            "event=virtual_display_keepalive_driver_ticks display=\(displayID) " +
                "raw=\(stats.raw) emitted=\(stats.emitted) " +
                "rawFPS=\(rawFPS.formatted(.number.precision(.fractionLength(1)))) " +
                "emittedFPS=\(emittedFPS.formatted(.number.precision(.fractionLength(1))))"
        )
    }
}

/// Tracks all active virtual-display keepalives for the host process.
@MainActor
final class VirtualDisplayKeepaliveController {
    /// Shared host-wide keepalive registry.
    static let shared = VirtualDisplayKeepaliveController()

    private var keepalives: [CGDirectDisplayID: VirtualDisplayKeepalive] = [:]

    /// Starts or reconfigures keepalive activity for a display.
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

    /// Restarts an existing keepalive or starts a new one when none exists.
    func restart(
        displayID: CGDirectDisplayID,
        spaceID: CGSSpaceID,
        refreshRate: Double,
        strength: VirtualDisplayKeepalive.Strength = .normal
    ) {
        if let existing = keepalives[displayID] {
            existing.reconfigure(spaceID: spaceID, refreshRate: refreshRate)
            existing.restart(strength: strength)
            return
        }
        start(displayID: displayID, spaceID: spaceID, refreshRate: refreshRate)
        if strength != .normal {
            keepalives[displayID]?.restart(strength: strength)
        }
    }

    /// Updates the keepalive window bounds for a display.
    func update(displayID: CGDirectDisplayID) {
        keepalives[displayID]?.updateBounds()
    }

    /// Stops and removes keepalive activity for a display.
    func stop(displayID: CGDirectDisplayID) {
        guard let keepalive = keepalives.removeValue(forKey: displayID) else { return }
        keepalive.stop()
    }
}

#endif
