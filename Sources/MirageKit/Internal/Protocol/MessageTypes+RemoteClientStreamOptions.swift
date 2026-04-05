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

    package init(
        displayMode: MirageStreamOptionsDisplayMode,
        statusOverlayEnabled: Bool
    ) {
        self.displayMode = displayMode
        self.statusOverlayEnabled = statusOverlayEnabled
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
    /// Optional app-stream bundle identifier the client should stop.
    package let stopAppBundleIdentifier: String?
    /// Optional desktop-stop request the client should perform.
    package let stopDesktopStream: Bool?

    package init(
        displayMode: MirageStreamOptionsDisplayMode? = nil,
        statusOverlayEnabled: Bool? = nil,
        desktopCursorPresentation: MirageDesktopCursorPresentation? = nil,
        stopAppBundleIdentifier: String? = nil,
        stopDesktopStream: Bool? = nil
    ) {
        self.displayMode = displayMode
        self.statusOverlayEnabled = statusOverlayEnabled
        self.desktopCursorPresentation = desktopCursorPresentation
        self.stopAppBundleIdentifier = stopAppBundleIdentifier
        self.stopDesktopStream = stopDesktopStream
    }
}
