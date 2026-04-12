//
//  MessageTypes+RemoteClientStreamOptions.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/4/26.
//

import Foundation

// MARK: - Remote Client Stream Options

/// Client-owned stream-option state mirrored back to the host UI.
package struct RemoteClientStreamOptionsStateMessage: Codable {
    /// Where the client currently surfaces stream options while streaming.
    package let displayMode: MirageStreamOptionsDisplayMode
    /// Whether the client is currently showing the in-stream status overlay.
    package let statusOverlayEnabled: Bool
    /// Whether the connected client currently allows desktop cursor lock controls.
    package let desktopCursorLockAvailable: Bool
    /// Current desktop cursor lock mode configured on the client.
    package let desktopCursorLockMode: MirageDesktopCursorLockMode

    package init(
        displayMode: MirageStreamOptionsDisplayMode,
        statusOverlayEnabled: Bool,
        desktopCursorLockAvailable: Bool,
        desktopCursorLockMode: MirageDesktopCursorLockMode
    ) {
        self.displayMode = displayMode
        self.statusOverlayEnabled = statusOverlayEnabled
        self.desktopCursorLockAvailable = desktopCursorLockAvailable
        self.desktopCursorLockMode = desktopCursorLockMode
    }
}

/// Host-issued command that asks the connected client to update stream-option state.
package struct RemoteClientStreamOptionsCommandMessage: Codable {
    /// Optional display-mode preference to apply on the client.
    package let displayMode: MirageStreamOptionsDisplayMode?
    /// Optional status-overlay preference to apply on the client.
    package let statusOverlayEnabled: Bool?
    /// Optional desktop cursor presentation to apply for the active desktop stream.
    package let desktopCursorPresentation: MirageDesktopCursorPresentation?
    /// Optional desktop cursor lock mode to apply on the client.
    package let desktopCursorLockMode: MirageDesktopCursorLockMode?
    /// Optional app-stream bundle identifier the client should stop.
    package let stopAppBundleIdentifier: String?
    /// Optional desktop-stop request the client should perform.
    package let stopDesktopStream: Bool?

    package init(
        displayMode: MirageStreamOptionsDisplayMode? = nil,
        statusOverlayEnabled: Bool? = nil,
        desktopCursorPresentation: MirageDesktopCursorPresentation? = nil,
        desktopCursorLockMode: MirageDesktopCursorLockMode? = nil,
        stopAppBundleIdentifier: String? = nil,
        stopDesktopStream: Bool? = nil
    ) {
        self.displayMode = displayMode
        self.statusOverlayEnabled = statusOverlayEnabled
        self.desktopCursorPresentation = desktopCursorPresentation
        self.desktopCursorLockMode = desktopCursorLockMode
        self.stopAppBundleIdentifier = stopAppBundleIdentifier
        self.stopDesktopStream = stopDesktopStream
    }
}
