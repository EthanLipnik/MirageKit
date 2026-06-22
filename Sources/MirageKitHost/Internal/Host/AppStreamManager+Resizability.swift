//
//  AppStreamManager+Resizability.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  App stream manager extensions.
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
#if os(macOS)
import ApplicationServices

// MARK: - Window Resizability Check

extension AppStreamManager {
    /// Returns whether the first accessibility window for a process exposes a settable size attribute.
    nonisolated func checkWindowResizability(processID: Int32) -> Bool {
        let appElement = AXUIElementCreateApplication(processID)

        let windows = HostAccessibilityWindowLookup.windows(in: appElement)

        // Accessibility does not expose a reliable CGWindowID bridge, so the first app window is the
        // least invasive signal for whether the app generally supports resize requests.
        guard let axWindow = windows.first else { return true }

        var isSettable: DarwinBoolean = false
        let result = AXUIElementIsAttributeSettable(axWindow, kAXSizeAttribute as CFString, &isSettable)

        if result == .success { return isSettable.boolValue }

        return true
    }
}

#endif
