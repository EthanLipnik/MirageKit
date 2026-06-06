//
//  SCShareableContent+MirageHost.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/11/26.
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
import ScreenCaptureKit

extension SCShareableContent {
    /// Current host capture inventory using Mirage's standard window-discovery policy.
    static func mirageHostContent() async throws -> SCShareableContent {
        try await excludingDesktopWindows(false, onScreenWindowsOnly: false)
    }
}
