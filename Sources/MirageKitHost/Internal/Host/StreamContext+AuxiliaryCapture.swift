//
//  StreamContext+AuxiliaryCapture.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/24/26.
//
//  Auxiliary window capture management for app streams.
//

import Foundation
import MirageKit

#if os(macOS)
import ScreenCaptureKit

extension StreamContext {
    /// Start capturing an auxiliary window associated with this stream's application.
    /// Resolves the `SCWindow` from `SCShareableContent`, creates an `AuxiliaryCaptureContext`,
    /// and begins independent window capture.
    ///
    /// - Parameters:
    ///   - windowID: Host window ID of the auxiliary window.
    ///   - parentFrame: Frame of the parent (primary) window for relative offset computation.
    /// - Returns: The auxiliary stream ID assigned to this capture.
    func startAuxiliaryCapture(
        windowID: WindowID,
        parentFrame: CGRect
    ) async throws -> StreamID {
        if let existing = auxiliaryCaptures[windowID] {
            return await existing.auxiliaryStreamID
        }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)

        guard let scWindow = content.windows.first(where: { WindowID($0.windowID) == windowID }),
              let scApp = scWindow.owningApplication else {
            throw MirageError.protocolError("Auxiliary window \(windowID) not found in SCShareableContent")
        }

        guard let display = content.displays.first else {
            throw MirageError.protocolError("No display available for auxiliary capture")
        }

        // Wrap SCK types for safe cross-actor transfer.
        let windowWrapper = SCWindowWrapper(window: scWindow)
        let applicationWrapper = SCApplicationWrapper(application: scApp)
        let displayWrapper = SCDisplayWrapper(display: display)

        // Derive a unique auxiliary stream ID from the parent stream ID and window ID.
        let auxiliaryStreamID = StreamID(truncatingIfNeeded: UInt32(streamID) &+ windowID)

        let context = AuxiliaryCaptureContext(
            windowID: windowID,
            parentStreamID: streamID,
            auxiliaryStreamID: auxiliaryStreamID,
            initialFrame: scWindow.frame
        )

        try await context.startCapture(
            windowWrapper: windowWrapper,
            applicationWrapper: applicationWrapper,
            displayWrapper: displayWrapper,
            encoderConfig: encoderConfig,
            latencyMode: latencyMode,
            onFrame: { [weak self] frame in
                self?.enqueueCapturedFrame(frame)
            }
        )

        auxiliaryCaptures[windowID] = context

        MirageLogger.stream(
            "Auxiliary capture registered: windowID=\(windowID), auxiliaryStreamID=\(auxiliaryStreamID), parentStreamID=\(streamID)"
        )

        return auxiliaryStreamID
    }

    /// Stop an individual auxiliary window capture and remove it from tracking.
    func stopAuxiliaryCapture(windowID: WindowID) async {
        guard let context = auxiliaryCaptures.removeValue(forKey: windowID) else { return }
        await context.stopCapture()
        MirageLogger.stream(
            "Auxiliary capture removed: windowID=\(windowID), parentStreamID=\(streamID)"
        )
    }

    /// Stop all auxiliary captures for this stream (used during stream teardown).
    func stopAllAuxiliaryCaptures() async {
        guard !auxiliaryCaptures.isEmpty else { return }
        let count = auxiliaryCaptures.count
        for (windowID, context) in auxiliaryCaptures {
            await context.stopCapture()
            MirageLogger.stream(
                "Auxiliary capture torn down: windowID=\(windowID), parentStreamID=\(streamID)"
            )
        }
        auxiliaryCaptures.removeAll()
        MirageLogger.stream("All auxiliary captures stopped for stream \(streamID) (count=\(count))")
    }
}

#endif
