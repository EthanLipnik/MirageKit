//
//  AuxiliaryCaptureContext.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/24/26.
//
//  Manages capture of a single auxiliary window (sheet, alert, dialog).
//

import Foundation
import MirageKit

#if os(macOS)
import ScreenCaptureKit

/// Manages the capture pipeline for a single auxiliary window.
/// Each auxiliary window gets its own `WindowCaptureEngine` using
/// `desktopIndependentWindow` capture, mirroring the primary window approach.
actor AuxiliaryCaptureContext {
    let windowID: WindowID
    let parentStreamID: StreamID
    let auxiliaryStreamID: StreamID

    private(set) var captureEngine: WindowCaptureEngine?
    private(set) var lastKnownFrame: CGRect
    private(set) var isCapturing: Bool = false

    init(
        windowID: WindowID,
        parentStreamID: StreamID,
        auxiliaryStreamID: StreamID,
        initialFrame: CGRect
    ) {
        self.windowID = windowID
        self.parentStreamID = parentStreamID
        self.auxiliaryStreamID = auxiliaryStreamID
        self.lastKnownFrame = initialFrame
    }

    /// Start capturing the auxiliary window using an independent window capture.
    func startCapture(
        windowWrapper: SCWindowWrapper,
        applicationWrapper: SCApplicationWrapper,
        displayWrapper: SCDisplayWrapper,
        encoderConfig: MirageEncoderConfiguration,
        latencyMode: MirageStreamLatencyMode,
        onFrame: @escaping @Sendable (CapturedFrame) -> Void
    ) async throws {
        guard !isCapturing else { return }

        let engine = WindowCaptureEngine(
            configuration: encoderConfig,
            latencyMode: latencyMode
        )
        captureEngine = engine

        try await engine.startCapture(
            window: windowWrapper.window,
            application: applicationWrapper.application,
            display: displayWrapper.display,
            onFrame: onFrame
        )

        isCapturing = true
        MirageLogger.stream(
            "Auxiliary capture started: windowID=\(windowID), streamID=\(auxiliaryStreamID), parentStreamID=\(parentStreamID)"
        )
    }

    /// Stop the auxiliary window capture and release the engine.
    func stopCapture() async {
        guard isCapturing else { return }
        isCapturing = false

        await captureEngine?.stopCapture()
        captureEngine = nil

        MirageLogger.stream(
            "Auxiliary capture stopped: windowID=\(windowID), streamID=\(auxiliaryStreamID)"
        )
    }

    /// Update the last known frame rectangle for position tracking.
    func updateFrame(_ frame: CGRect) {
        lastKnownFrame = frame
    }
}

#endif
