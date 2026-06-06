//
//  MirageHostCaptureBenchmark+Source.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/10/26.
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
import Foundation

#if os(macOS)
import AppKit

/// Window placement metadata used by the host app while preparing a capture benchmark source.
@_spi(HostApp)
@MainActor
public final class MirageHostCaptureBenchmarkWindowConfiguration {
    /// Benchmark stage being prepared.
    public let stage: MirageDiagnostics.MirageHostCaptureBenchmarkStage
    /// Capture mode selection being measured.
    public let modeSelection: MirageDiagnostics.MirageHostCaptureBenchmarkModeSelection
    /// Display that should contain the prepared source window.
    public let displayID: CGDirectDisplayID
    /// Bounds of the target display in global display coordinates.
    public let displayBounds: CGRect
    /// Pixel size of the target display.
    public let pixelSize: CGSize

    private let spaceID: CGSSpaceID

    init(
        stage: MirageDiagnostics.MirageHostCaptureBenchmarkStage,
        modeSelection: MirageDiagnostics.MirageHostCaptureBenchmarkModeSelection,
        displayID: CGDirectDisplayID,
        displayBounds: CGRect,
        pixelSize: CGSize,
        spaceID: CGSSpaceID
    ) {
        self.stage = stage
        self.modeSelection = modeSelection
        self.displayID = displayID
        self.displayBounds = displayBounds
        self.pixelSize = pixelSize
        self.spaceID = spaceID
    }

    /// Places a source window on the benchmark display and assigns it to the benchmark space.
    public func install(window: NSWindow) {
        let targetFrame = resolvedTargetFrame(for: displayID, fallback: displayBounds)
        window.setFrame(targetFrame, display: true)
        window.orderFront(nil)
        let windowID = CGWindowID(window.windowNumber)
        guard windowID != 0 else {
            window.displayIfNeeded()
            return
        }
        _ = CGSWindowSpaceBridge.setCurrentSpaceForDisplay(displayID, spaceID: spaceID)
        CGSWindowSpaceBridge.moveWindowToSpace(windowID, spaceID: spaceID)
        window.setFrame(targetFrame, display: true)
        _ = CGSWindowSpaceBridge.bringWindowToFront(windowID)
        window.displayIfNeeded()
    }

    private func resolvedTargetFrame(
        for displayID: CGDirectDisplayID,
        fallback: CGRect
    ) -> CGRect {
        if let screen = NSScreen.screens.first(where: {
            guard let number = $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return false
            }
            return CGDirectDisplayID(number.uint32Value) == displayID
        }) {
            return screen.frame
        }
        return fallback
    }
}

@_spi(HostApp)
public final class MirageHostCaptureBenchmarkSourceClock: @unchecked Sendable {
    private let stateLock = NSLock()
    private var displayTickCount: UInt64 = 0
    private var measurementStartTickCount: UInt64 = 0

    /// Creates an empty source clock.
    public init() {}

    /// Records one display tick produced by the prepared benchmark source.
    public func noteDisplayTick() {
        stateLock.withLock {
            displayTickCount &+= 1
        }
    }

    /// Starts a measurement interval at the current tick count.
    public func beginMeasurement() {
        stateLock.withLock {
            measurementStartTickCount = displayTickCount
        }
    }

    /// Cancels the active measurement interval and resets the start tick.
    public func cancelMeasurement() {
        stateLock.withLock {
            measurementStartTickCount = displayTickCount
        }
    }

    /// Completes the current measurement interval and returns the measured tick rate.
    public func completeMeasurement(durationSeconds: Double) -> Double? {
        let clampedDuration = max(0.001, durationSeconds)
        let tickDelta = stateLock.withLock { () -> UInt64 in
            let delta = displayTickCount >= measurementStartTickCount
                ? displayTickCount - measurementStartTickCount
                : 0
            measurementStartTickCount = displayTickCount
            return delta
        }
        guard tickDelta > 0 else { return nil }
        return Double(tickDelta) / clampedDuration
    }
}

@_spi(HostApp)
/// Prepared source-window metadata returned by the host app.
public struct MirageHostCaptureBenchmarkPreparedSource: Sendable {
    /// Window identifier for the prepared benchmark source.
    public let windowID: CGWindowID
    /// Process identifier for the application that owns the source window.
    public let applicationPID: pid_t
    /// Display containing the prepared benchmark source.
    public let displayID: CGDirectDisplayID
    /// Expected source window frame used to validate source placement.
    public let expectedWindowFrame: CGRect?
    /// Optional clock that reports source-driven display ticks during measurement.
    public let sourceClock: MirageHostCaptureBenchmarkSourceClock?

    /// Creates metadata for a prepared benchmark source window.
    public init(
        windowID: CGWindowID,
        applicationPID: pid_t,
        displayID: CGDirectDisplayID,
        expectedWindowFrame: CGRect? = nil,
        sourceClock: MirageHostCaptureBenchmarkSourceClock? = nil
    ) {
        self.windowID = windowID
        self.applicationPID = applicationPID
        self.displayID = displayID
        self.expectedWindowFrame = expectedWindowFrame
        self.sourceClock = sourceClock
    }
}
#endif
