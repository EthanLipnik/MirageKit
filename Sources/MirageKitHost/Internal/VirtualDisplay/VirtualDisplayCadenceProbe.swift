//
//  VirtualDisplayCadenceProbe.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/15/26.
//

import AppKit
import CoreGraphics
import Foundation
import QuartzCore

#if os(macOS)

/// Measures callback cadence for a virtual display using a screen display link.
@MainActor
final class VirtualDisplayCadenceProbe: NSObject, @unchecked Sendable {
    private let displayID: CGDirectDisplayID
    private let stateLock = NSLock()

    private var displayLink: CADisplayLink?
    private var isRunning = false
    private var measurementActive = false
    private var callbackCount: UInt64 = 0

    /// Creates a cadence probe for `displayID`, returning `nil` if AppKit cannot attach.
    init?(displayID: CGDirectDisplayID) {
        self.displayID = displayID

        guard let screen = NSScreen.screens.first(where: { $0.mirageDisplayID == displayID }) else {
            MirageLogger.error(
                .host,
                "Failed to create display cadence probe for display \(displayID): matching screen unavailable"
            )
            return nil
        }

        super.init()
        displayLink = screen.displayLink(target: self, selector: #selector(handleDisplayTick(_:)))
    }

    /// Stops the display link before release.
    isolated deinit {
        stop()
    }

    /// Starts the display link used for measurement callbacks.
    func start() -> Bool {
        guard let displayLink else { return false }
        guard !isRunning else { return true }

        displayLink.add(to: .main, forMode: .common)
        isRunning = true
        return true
    }

    /// Stops the display link when measurement is no longer needed.
    func stop() {
        guard let displayLink, isRunning else { return }
        displayLink.invalidate()
        self.displayLink = nil
        isRunning = false
    }

    /// Resets counters and begins counting display-link callbacks.
    func beginMeasurement() {
        stateLock.lock()
        defer { stateLock.unlock() }
        callbackCount = 0
        measurementActive = true
    }

    /// Cancels the active measurement and clears accumulated callback state.
    func cancelMeasurement() {
        stateLock.lock()
        defer { stateLock.unlock() }
        callbackCount = 0
        measurementActive = false
    }

    /// Finishes measurement and returns callbacks per second when callbacks were observed.
    func completeMeasurement(durationSeconds: Double) -> Double? {
        let clampedDuration = max(0.001, durationSeconds)
        stateLock.lock()
        defer { stateLock.unlock() }
        let measuredCallbacks = callbackCount
        callbackCount = 0
        measurementActive = false
        guard measuredCallbacks > 0 else { return nil }
        return Double(measuredCallbacks) / clampedDuration
    }

    /// Records a callback only while a measurement window is active.
    @objc private func handleDisplayTick(_ displayLink: CADisplayLink) {
        stateLock.lock()
        defer { stateLock.unlock() }
        if measurementActive {
            callbackCount &+= 1
        }
    }
}

private extension NSScreen {
    var mirageDisplayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

#endif
