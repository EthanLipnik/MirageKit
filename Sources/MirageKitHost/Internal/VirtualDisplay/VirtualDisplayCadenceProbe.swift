//
//  VirtualDisplayCadenceProbe.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/15/26.
//

import CoreGraphics
import CoreVideo
import Foundation

#if os(macOS)

final class VirtualDisplayCadenceProbe: @unchecked Sendable {
    private let displayID: CGDirectDisplayID
    private let stateLock = NSLock()

    private var displayLink: CVDisplayLink?
    private var isRunning = false
    private var measurementActive = false
    private var callbackCount: UInt64 = 0

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
                "Failed to start display cadence probe for display \(displayID): CVReturn=\(status)"
            )
            return false
        }

        isRunning = true
        return true
    }

    func stop() {
        guard let displayLink else { return }
        guard isRunning else { return }
        CVDisplayLinkStop(displayLink)
        isRunning = false
    }

    func beginMeasurement() {
        stateLock.lock()
        callbackCount = 0
        measurementActive = true
        stateLock.unlock()
    }

    func cancelMeasurement() {
        stateLock.lock()
        callbackCount = 0
        measurementActive = false
        stateLock.unlock()
    }

    func completeMeasurement(durationSeconds: Double) -> Double? {
        let clampedDuration = max(0.001, durationSeconds)
        stateLock.lock()
        let measuredCallbacks = callbackCount
        callbackCount = 0
        measurementActive = false
        stateLock.unlock()
        guard measuredCallbacks > 0 else { return nil }
        return Double(measuredCallbacks) / clampedDuration
    }

    private func handleDisplayTick() {
        stateLock.lock()
        if measurementActive {
            callbackCount &+= 1
        }
        stateLock.unlock()
    }
}

#endif
