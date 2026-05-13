//
//  StreamContext+StartupLogging.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/13/26.
//

import Foundation
import MirageKit

#if os(macOS)
extension StreamContext {
    /// Resets startup telemetry state for a new stream startup sequence.
    func setStartupBaseTime(_ baseTime: CFAbsoluteTime, label: String) {
        startupBaseTime = baseTime
        startupLabel = label
        startupFirstCaptureLogged = false
        startupFirstEncodeLogged = false
        startupRegistrationLogged = false
    }

    /// Logs a startup milestone relative to the active startup baseline.
    func logStartupEvent(_ event: String) {
        guard startupBaseTime > 0 else { return }
        let deltaMs = Int((CFAbsoluteTimeGetCurrent() - startupBaseTime) * 1000)
        let label = startupLabel.isEmpty ? "stream \(streamID)" : startupLabel
        MirageLogger.stream("\(label) start: \(event) (+\(deltaMs)ms)")
    }
}
#endif
