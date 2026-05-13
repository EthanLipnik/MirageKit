//
//  MirageWindow.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/2/26.
//

import CoreGraphics

/// Capturable host window advertised to Mirage clients.
public struct MirageWindow: Identifiable, Hashable, Sendable, Codable {
    /// Unique host window identifier.
    public let id: WindowID

    /// Window title, when the host can resolve one.
    public let title: String?

    /// Application that owns this window.
    public let application: MirageApplication?

    /// Window frame in host screen coordinates.
    public let frame: CGRect

    /// Whether the window is currently visible on screen.
    public let isOnScreen: Bool

    /// Window layer, where higher values are closer to the front.
    public let windowLayer: Int

    /// Number of tabs in this window. Non-tabbed windows use `1`.
    public let tabCount: Int

    /// Creates capturable host-window metadata for clients.
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

    /// Creates a copy of this window with a new tab count.
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

    /// Display name for the window, falling back to the owning app name.
    public var displayName: String {
        if let title, !title.isEmpty { return title }
        return application?.name ?? "Untitled Window"
    }
}
