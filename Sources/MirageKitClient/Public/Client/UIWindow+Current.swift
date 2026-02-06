//
//  UIWindow+Current.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Key window lookup helper for iOS window scenes.
//

import MirageKit
#if os(iOS)
import UIKit

public extension UIWindow {
    /// Returns the current key window from connected window scenes.
    /// For SwiftUI views, prefer WindowSceneReader for view hierarchy detection.
    static var current: UIWindow? {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows where window.isKeyWindow {
                return window
            }
        }
        return nil
    }
}
#endif
