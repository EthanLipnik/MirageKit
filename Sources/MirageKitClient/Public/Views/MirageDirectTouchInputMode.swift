//
//  MirageDirectTouchInputMode.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/9/26.
//
//  Touch behavior options for touch-capable clients.
//

import Foundation
#if os(iOS)
import UIKit
#endif

/// Determines how screen touches are translated into host input.
public enum MirageDirectTouchInputMode: String, CaseIterable, Codable, Sendable {
    /// Direct touches scroll natively; taps click; long press and two-finger drag perform left drag.
    case normal

    /// Simulated trackpad-style cursor movement.
    case dragCursor

    public var displayName: String {
        switch self {
        case .normal: "Direct"
        case .dragCursor: "Simulated Trackpad"
        }
    }

    /// Default touch translation mode for the current client device.
    public static var defaultForCurrentDevice: MirageDirectTouchInputMode {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone ? .dragCursor : .normal
        #else
        .normal
        #endif
    }

    /// Resolves persisted mode values while preserving legacy virtual trackpad preferences.
    public static func fromPersistedRawValue(
        _ rawValue: String,
        enableVirtualTrackpad: Bool,
        hasStoredLegacyVirtualTrackpadPreference: Bool = false,
        defaultMode: MirageDirectTouchInputMode = .defaultForCurrentDevice
    ) -> MirageDirectTouchInputMode {
        if let mode = MirageDirectTouchInputMode(rawValue: rawValue) {
            return mode
        }

        if hasStoredLegacyVirtualTrackpadPreference {
            return enableVirtualTrackpad ? .dragCursor : .normal
        }

        return defaultMode
    }
}
