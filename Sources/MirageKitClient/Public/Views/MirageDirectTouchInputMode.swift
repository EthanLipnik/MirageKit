//
//  MirageDirectTouchInputMode.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/9/26.
//
//  Touch behavior options for touch-capable clients.
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

/// Determines how screen touches are translated into host input.
public enum MirageDirectTouchInputMode: String, CaseIterable, Codable, Sendable {
    /// UserDefaults key for the selected direct-touch mode.
    public static let defaultsKey = "directTouchInputMode"

    /// Direct touches scroll natively; taps click; stationary long press right-clicks;
    /// long-press drag and two-finger drag perform left drag.
    case normal

    /// Simulated trackpad-style cursor movement.
    case dragCursor

    /// User-visible mode name for settings and menus.
    public var displayName: String {
        switch self {
        case .normal: "Direct"
        case .dragCursor: "Simulated Trackpad"
        }
    }

    /// Default touch translation mode for the current client device.
    public static let defaultForCurrentDevice: MirageDirectTouchInputMode = {
        #if os(iOS)
        MirageSupportInfo.hardwareModel.hasPrefix("iPhone") ? .dragCursor : .normal
        #else
        .normal
        #endif
    }()

    /// Resolves persisted mode values, falling back when storage contains an unknown raw value.
    public static func fromPersistedRawValue(
        _ rawValue: String,
        defaultMode: MirageDirectTouchInputMode = .defaultForCurrentDevice
    ) -> MirageDirectTouchInputMode {
        if let mode = MirageDirectTouchInputMode(rawValue: rawValue) {
            return mode
        }

        return defaultMode
    }
}
