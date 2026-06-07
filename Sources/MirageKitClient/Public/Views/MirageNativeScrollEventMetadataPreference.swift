//
//  MirageNativeScrollEventMetadataPreference.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/8/26.
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
import Foundation

/// Preference namespace for native scroll-event metadata capture.
public enum MirageNativeScrollEventMetadataPreference {
    /// UserDefaults key for enabling metadata-backed native scroll events.
    public static let defaultsKey = "nativeScrollEventMetadataEnabled"
}
