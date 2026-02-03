//
//  StreamContext+VirtualDisplayRebind.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/27/26.
//
//  Shared virtual display resolution retry and rebind coordination.
//

import Foundation

#if os(macOS)
import ScreenCaptureKit

extension StreamContext {
    struct VirtualDisplayTargets {
        let window: SCWindowWrapper
        let application: SCApplicationWrapper
        let display: SCDisplayWrapper
    }

    func resolveVirtualDisplayTargets(
        windowID: WindowID,
        applicationPID: pid_t,
        displayID: CGDirectDisplayID,
        label: String,
        maxAttempts: Int = 8,
        initialDelayMs: Int = 80
    )
    async throws -> VirtualDisplayTargets {
        let attempts = max(1, maxAttempts)
        var delayMs = max(40, initialDelayMs)

        for attempt in 1 ... attempts {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)

                let scDisplay = content.displays.first(where: { $0.displayID == displayID })
                let scWindow = content.windows.first(where: { $0.windowID == windowID })
                let scApplication = content.applications.first(where: { $0.processID == applicationPID })

                if let scDisplay, let scWindow, let scApplication {
                    if attempt > 1 { MirageLogger.stream("Resolved virtual display targets on attempt \(attempt) (\(label))") }
                    return VirtualDisplayTargets(
                        window: SCWindowWrapper(window: scWindow),
                        application: SCApplicationWrapper(application: scApplication),
                        display: SCDisplayWrapper(display: scDisplay)
                    )
                }

                if attempt < attempts {
                    let missingParts = [
                        scDisplay == nil ? "display" : nil,
                        scWindow == nil ? "window" : nil,
                        scApplication == nil ? "application" : nil,
                    ].compactMap(\.self)
                    let missingLabel = missingParts.joined(separator: ", ")
                    MirageLogger
                        .stream(
                            "Virtual display targets missing (\(missingLabel)) on attempt \(attempt)/\(attempts) (\(label)); retrying in \(delayMs)ms"
                        )
                    try? await Task.sleep(for: .milliseconds(Int64(delayMs)))
                    delayMs = min(1000, Int(Double(delayMs) * 1.6))
                }
            } catch {
                if attempt >= attempts { throw error }
                MirageLogger.error(
                    .stream,
                    "Failed to query SCShareableContent (\(label)) attempt \(attempt)/\(attempts): \(error)"
                )
                try? await Task.sleep(for: .milliseconds(Int64(delayMs)))
                delayMs = min(1000, Int(Double(delayMs) * 1.6))
            }
        }

        throw MirageError.protocolError("Unable to resolve virtual display targets for stream \(streamID) (\(label))")
    }

    func rebindToSharedDisplay(
        newContext: SharedVirtualDisplayManager.DisplaySnapshot,
        reason: String
    )
    async throws {
        guard isRunning, useVirtualDisplay else { return }
        guard let currentContext = virtualDisplayContext else { return }
        guard currentContext.generation != newContext.generation else { return }
        guard isReadyForSharedDisplayRebind() else {
            virtualDisplayContext = newContext
            sharedDisplayGeneration = newContext.generation
            MirageLogger.stream("Shared display rebind deferred for stream \(streamID): pipeline not ready")
            return
        }
        guard applicationProcessID != 0 else {
            virtualDisplayContext = newContext
            sharedDisplayGeneration = newContext.generation
            MirageLogger.stream("Shared display rebind skipped for stream \(streamID): missing application PID")
            return
        }

        isResizing = true
        defer { isResizing = false }

        currentContentRect = .zero
        dimensionToken &+= 1
        MirageLogger
            .stream("Rebinding stream \(streamID) to shared display generation \(newContext.generation) (\(reason))")
        await packetSender?.bumpGeneration(reason: "shared display rebind")
        resetPipelineStateForReconfiguration(reason: "shared display rebind")

        await captureEngine?.stopCapture()

        virtualDisplayContext = newContext
        sharedDisplayGeneration = newContext.generation

        let displayBounds = CGVirtualDisplayBridge.getDisplayBounds(
            newContext.displayID,
            knownResolution: newContext.resolution
        )
        try await WindowSpaceManager.shared.moveWindow(
            windowID,
            toSpaceID: newContext.spaceID,
            displayID: newContext.displayID,
            displayBounds: displayBounds
        )

        let targets = try await resolveVirtualDisplayTargets(
            windowID: windowID,
            applicationPID: applicationProcessID,
            displayID: newContext.displayID,
            label: "shared display rebind"
        )

        let scWindow = targets.window.window
        let captureScaleFactor: CGFloat = 2.0
        let captureTarget = streamTargetDimensions(windowFrame: scWindow.frame, scaleFactor: captureScaleFactor)
        baseCaptureSize = CGSize(width: captureTarget.width, height: captureTarget.height)
        streamScale = resolvedStreamScale(
            for: baseCaptureSize,
            requestedScale: requestedStreamScale,
            logLabel: "Resolution cap"
        )
        let outputSize = scaledOutputSize(for: baseCaptureSize)
        currentCaptureSize = outputSize
        currentEncodedSize = outputSize
        captureMode = .window
        lastWindowFrame = scWindow.frame
        updateQueueLimits()

        if let encoder {
            try await encoder.updateDimensions(
                width: Int(outputSize.width),
                height: Int(outputSize.height)
            )
            let resolvedPixelFormat = await encoder.getActivePixelFormat()
            activePixelFormat = resolvedPixelFormat
        }

        await applyDerivedQuality(for: outputSize, logLabel: "Shared display rebind")

        let captureConfig = encoderConfig.withOverrides(pixelFormat: activePixelFormat)
        let newCaptureEngine = WindowCaptureEngine(
            configuration: captureConfig,
            latencyMode: latencyMode,
            captureFrameRate: captureFrameRate
        )
        captureEngine = newCaptureEngine

        try await newCaptureEngine.startCapture(
            window: targets.window.window,
            application: targets.application.application,
            display: targets.display.display,
            knownScaleFactor: 2.0,
            outputScale: streamScale
        ) { [weak self] frame in
            self?.enqueueCapturedFrame(frame)
        }
        await refreshCaptureCadence()

        await encoder?.forceKeyframe()
        MirageLogger.stream("Shared display rebind complete for stream \(streamID)")
    }
}

#endif
