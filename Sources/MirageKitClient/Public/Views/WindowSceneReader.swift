//
//  WindowSceneReader.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/21/26.
//

import MirageKit
#if os(iOS)
import SwiftUI
import UIKit

// MARK: - WindowSceneReader

/// A view that reads the current window scene and provides it via callback.
///
/// This is more reliable than `UIApplication.shared.connectedScenes` because it
/// gets the window scene directly from the view's actual window in the hierarchy.
///
/// Includes periodic polling to catch screen changes that may not trigger
/// standard UIKit callbacks (e.g., Stage Manager transitions).
public struct WindowSceneReader: UIViewRepresentable {
    public var onUpdate: (UIWindowScene?) -> Void

    /// Polling interval in seconds (default 2 seconds).
    public var pollingInterval: TimeInterval = 2.0

    /// Creates a window scene reader.
    /// - Parameters:
    ///   - pollingInterval: Interval in seconds for polling changes.
    ///   - onUpdate: Callback with the latest window scene.
    public init(pollingInterval: TimeInterval = 2.0, onUpdate: @escaping (UIWindowScene?) -> Void) {
        self.pollingInterval = pollingInterval
        self.onUpdate = onUpdate
    }

    public func makeUIView(context _: Context) -> WindowSceneCallbackView {
        let view = WindowSceneCallbackView()
        view.pollingInterval = pollingInterval
        view.onUpdate = { [weak view] in
            onUpdate(view?.window?.windowScene)
        }
        return view
    }

    public func updateUIView(_ uiView: WindowSceneCallbackView, context _: Context) {
        Task { @MainActor in
            onUpdate(uiView.window?.windowScene)
        }
    }

    public final class WindowSceneCallbackView: UIView {
        var onUpdate: (() -> Void)?
        var pollingInterval: TimeInterval = 2.0

        private weak var lastKnownScreen: UIScreen?
        private var displayLink: CADisplayLink?
        private var lastCheckTime: CFTimeInterval = 0

        override public func didMoveToWindow() {
            super.didMoveToWindow()
            updateLastKnownScreen()
            onUpdate?()

            if window != nil { startPolling() } else {
                stopPolling()
            }
        }

        override public func didMoveToSuperview() {
            super.didMoveToSuperview()
            onUpdate?()
        }

        override public func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
            super.traitCollectionDidChange(previousTraitCollection)
            updateLastKnownScreen()
            onUpdate?()
        }

        private func startPolling() {
            guard displayLink == nil else { return }

            displayLink = CADisplayLink(target: self, selector: #selector(checkForScreenChange))
            displayLink?.add(to: .main, forMode: .common)
            lastCheckTime = CACurrentMediaTime()
        }

        private func stopPolling() {
            displayLink?.invalidate()
            displayLink = nil
        }

        @objc
        private func checkForScreenChange(_ link: CADisplayLink) {
            let currentTime = link.timestamp

            guard currentTime - lastCheckTime >= pollingInterval else { return }
            lastCheckTime = currentTime

            let currentScreen = window?.windowScene?.screen ?? window?.screen
            if currentScreen !== lastKnownScreen {
                lastKnownScreen = currentScreen
                onUpdate?()
            }
        }

        private func updateLastKnownScreen() {
            lastKnownScreen = window?.windowScene?.screen ?? window?.screen
        }

        deinit {
            stopPolling()
        }
    }
}

// MARK: - Screen Reader View Modifier

/// A view modifier that provides the current screen to child views.
public struct ScreenReaderModifier: ViewModifier {
    @State private var currentScreen: UIScreen?

    let onScreenChange: ((UIScreen) -> Void)?

    public init(onScreenChange: ((UIScreen) -> Void)? = nil) {
        self.onScreenChange = onScreenChange
    }

    public func body(content: Content) -> some View {
        content
            .background(
                WindowSceneReader { windowScene in
                    if windowScene == nil { MirageLogger.debug(.client, "WindowSceneReader: windowScene is nil") }
                    let screenFromScene = windowScene?.screen
                    let screen = screenFromScene ?? UIScreen.main
                    if windowScene != nil, screenFromScene == nil { MirageLogger.debug(.client, "WindowSceneReader: windowScene exists but screen is nil") }
                    if screen !== currentScreen {
                        MirageLogger.debug(.client, "WindowSceneReader: screen changed to \(screen.bounds)")
                        Task { @MainActor in
                            currentScreen = screen
                            onScreenChange?(screen)
                        }
                    }
                }
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
            )
            .environment(\.currentScreen, currentScreen)
    }
}

// MARK: - Environment Key

private struct CurrentScreenKey: EnvironmentKey {
    static let defaultValue: UIScreen? = nil
}

public extension EnvironmentValues {
    /// The current screen that the view is displayed on.
    var currentScreen: UIScreen? {
        get { self[CurrentScreenKey.self] }
        set { self[CurrentScreenKey.self] = newValue }
    }
}

// MARK: - View Extensions

public extension View {
    /// Adds screen reading capability to this view and its descendants.
    func readScreen(onChange: ((UIScreen) -> Void)? = nil) -> some View {
        modifier(ScreenReaderModifier(onScreenChange: onChange))
    }
}
#endif
