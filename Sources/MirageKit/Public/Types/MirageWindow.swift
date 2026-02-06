//
//  MirageWindow.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/2/26.
//

import CoreGraphics
import Foundation

/// Represents a capturable window on the host system
public struct MirageWindow: Identifiable, Hashable, Sendable, Codable {
    /// Unique window identifier
    public let id: WindowID

    /// Window title (may be nil for some windows)
    public let title: String?

    /// The application that owns this window
    public let application: MirageApplication?

    /// Window frame in screen coordinates
    public let frame: CGRect

    /// Whether the window is currently visible on screen
    public let isOnScreen: Bool

    /// Window layer (higher = more in front)
    public let windowLayer: Int

    /// Number of tabs in this window (1 for non-tabbed windows)
    public let tabCount: Int

    public init(
        id: WindowID,
        title: String?,
        application: MirageApplication?,
        frame: CGRect,
        isOnScreen: Bool,
        windowLayer: Int,
        tabCount: Int = 1
    ) {
        self.id = id
        self.title = title
        self.application = application
        self.frame = frame
        self.isOnScreen = isOnScreen
        self.windowLayer = windowLayer
        self.tabCount = tabCount
    }

    /// Creates a copy of this window with the specified tab count
    public func withTabCount(_ count: Int) -> MirageWindow {
        MirageWindow(
            id: id,
            title: title,
            application: application,
            frame: frame,
            isOnScreen: isOnScreen,
            windowLayer: windowLayer,
            tabCount: count
        )
    }

    /// Display name for the window (uses app name if title is empty)
    public var displayName: String {
        if let title, !title.isEmpty { return title }
        return application?.name ?? "Untitled Window"
    }
}
