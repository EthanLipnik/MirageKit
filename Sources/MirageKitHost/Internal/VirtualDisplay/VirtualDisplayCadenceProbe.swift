//
//  VirtualDisplayCadenceProbe.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/15/26.
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
import CoreGraphics
import CoreVideo
import Foundation

#if os(macOS)

/// Measures callback cadence for a virtual display using a CoreVideo display link.
final class VirtualDisplayCadenceProbe: @unchecked Sendable {
    private let displayID: CGDirectDisplayID
    private let stateLock = NSLock()

    private var displayLink: CVDisplayLink?
    private var isRunning = false
    private var measurementActive = false
    private var callbackCount: UInt64 = 0

    /// Creates a cadence probe for `displayID`, returning `nil` if CoreVideo cannot attach.
    init?(displayID: CGDirectDisplayID) {
        self.displayID = displayID

        var createdDisplayLink: CVDisplayLink?
        let creationStatus = CVDisplayLinkCreateWithCGDisplay(displayID, &createdDisplayLink)
        guard creationStatus == kCVReturnSuccess, let createdDisplayLink else {
            MirageLogger.error(
                .host,
                "Failed to create display cadence probe for display \(displayID): CVReturn=\(creationStatus)"
            )
            return nil
        }

        let callbackStatus = CVDisplayLinkSetOutputCallback(
            createdDisplayLink,
            { _, _, _, _, _, userInfo in
                guard let userInfo else { return kCVReturnError }
                let probe = Unmanaged<VirtualDisplayCadenceProbe>
                    .fromOpaque(userInfo)
                    .takeUnretainedValue()
                probe.handleDisplayTick()
                return kCVReturnSuccess
            },
            UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        )
        guard callbackStatus == kCVReturnSuccess else {
            MirageLogger.error(
                .host,
                "Failed to attach display cadence callback for display \(displayID): CVReturn=\(callbackStatus)"
            )
            return nil
        }

        displayLink = createdDisplayLink
    }

    /// Stops the display link before release.
    deinit {
        stop()
    }

    /// Starts the display link used for measurement callbacks.
    func start() -> Bool {
        guard let displayLink else { return false }
        guard !isRunning else { return true }

        let status = CVDisplayLinkStart(displayLink)
        guard status == kCVReturnSuccess else {
            MirageLogger.error(
                .host,
                "Failed to start display cadence probe for display \(displayID): CVReturn=\(status)"
            )
            return false
        }

        isRunning = true
        return true
    }

    /// Stops the display link when measurement is no longer needed.
    func stop() {
        guard let displayLink, isRunning else { return }
        CVDisplayLinkStop(displayLink)
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
    private func handleDisplayTick() {
        stateLock.lock()
        defer { stateLock.unlock() }
        if measurementActive {
            callbackCount &+= 1
        }
    }
}

#endif
