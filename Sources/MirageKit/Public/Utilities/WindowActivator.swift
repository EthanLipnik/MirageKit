//
//  WindowActivator.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/5/26.
//

import Foundation

#if os(macOS)
import AppKit
import ApplicationServices

/// Result of an activation attempt
public enum ActivationResult {
    case success(method: String)
    case partialSuccess(method: String, message: String)
    case failure(method: String, error: String)
}

/// Robust window activation utility that works on headless Macs.
/// Tries multiple activation methods in sequence until one succeeds.
public final class WindowActivator {

    /// Activation methods in priority order
    public enum ActivationMethod: CaseIterable, Sendable {
        case nsRunningApplication      // Standard AppKit activation
        case axFrontmostAttribute      // Set AXFrontmost on app element
        case axRaiseAndFocus           // Raise window + set focused window
        case appleScript               // AppleScript activation (most reliable on headless)
        case nsWorkspaceOpen           // NSWorkspace.open with activation config
    }

    /// Configuration for activation attempts
    public struct Configuration: Sendable {
        /// Methods to try, in order
        public var methods: [ActivationMethod]

        /// Maximum time to wait for activation to take effect (per method)
        public var verificationTimeout: TimeInterval

        /// Whether to log detailed debug info
        public var verbose: Bool

        public static let `default` = Configuration(
            methods: ActivationMethod.allCases,
            verificationTimeout: 0.1,
            verbose: false
        )

        /// Fast configuration - skips slow methods like AppleScript
        public static let fast = Configuration(
            methods: [.nsRunningApplication, .axFrontmostAttribute, .axRaiseAndFocus],
            verificationTimeout: 0.05,
            verbose: false
        )

        /// Headless-optimized - prioritizes methods known to work without display
        public static let headless = Configuration(
            methods: [.appleScript, .axFrontmostAttribute, .nsRunningApplication, .axRaiseAndFocus],
            verificationTimeout: 0.15,
            verbose: false
        )

        public init(methods: [ActivationMethod], verificationTimeout: TimeInterval, verbose: Bool) {
            self.methods = methods
            self.verificationTimeout = verificationTimeout
            self.verbose = verbose
        }
    }

    private let configuration: Configuration

    public init(configuration: Configuration = .default) {
        self.configuration = configuration
    }

    // MARK: - Public API

    /// Activate an application and optionally raise a specific window
    /// - Parameters:
    ///   - app: The MirageApplication to activate
    ///   - window: Optional specific window to raise (if nil, just activates app)
    ///   - axWindow: Pre-fetched AXUIElement for the window (optional, avoids re-lookup)
    /// - Returns: Result indicating which method succeeded or all failures
    @discardableResult
    public func activate(
        app: MirageApplication,
        window: MirageWindow? = nil,
        axWindow: AXUIElement? = nil
    ) -> ActivationResult {

        // Validate process exists
        guard let runningApp = NSRunningApplication(processIdentifier: app.id) else {
            return .failure(method: "validation", error: "Process \(app.id) not running")
        }

        var lastPartialSuccess: ActivationResult?

        // Try each method in order
        for method in configuration.methods {
            let result = tryMethod(method, app: app, runningApp: runningApp, window: window, axWindow: axWindow)

            switch result {
            case .success:
                if configuration.verbose {
                    MirageLogger.log(.windowActivator, "\(method) succeeded for \(app.name)")
                }
                return result
            case .partialSuccess:
                if configuration.verbose {
                    MirageLogger.log(.windowActivator, "\(method) partial success for \(app.name)")
                }
                lastPartialSuccess = result
                continue
            case .failure(_, let error):
                if configuration.verbose {
                    MirageLogger.log(.windowActivator, "\(method) failed: \(error)")
                }
                continue
            }
        }

        // Return partial success if we had one, otherwise failure
        if let partial = lastPartialSuccess {
            return partial
        }

        return .failure(method: "all", error: "All activation methods failed")
    }

    // MARK: - Individual Activation Methods

    private func tryMethod(
        _ method: ActivationMethod,
        app: MirageApplication,
        runningApp: NSRunningApplication,
        window: MirageWindow?,
        axWindow: AXUIElement?
    ) -> ActivationResult {
        switch method {
        case .nsRunningApplication:
            return tryNSRunningApplicationActivation(runningApp: runningApp, axWindow: axWindow)

        case .axFrontmostAttribute:
            return tryAXFrontmostActivation(app: app, axWindow: axWindow)

        case .axRaiseAndFocus:
            return tryAXRaiseAndFocus(app: app, axWindow: axWindow)

        case .appleScript:
            return tryAppleScriptActivation(app: app)

        case .nsWorkspaceOpen:
            return tryNSWorkspaceActivation(app: app)
        }
    }

    /// Method 1: Standard NSRunningApplication activation
    private func tryNSRunningApplicationActivation(
        runningApp: NSRunningApplication,
        axWindow: AXUIElement?
    ) -> ActivationResult {
        let success = runningApp.activate(options: [.activateIgnoringOtherApps])

        if !success {
            return .failure(method: "NSRunningApplication", error: "activate() returned false")
        }

        // Brief wait then verify
        Thread.sleep(forTimeInterval: configuration.verificationTimeout)

        if runningApp.isActive {
            // Also raise the window if we have it
            if let axWindow = axWindow {
                AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
            }
            return .success(method: "NSRunningApplication")
        }

        return .failure(method: "NSRunningApplication", error: "App not active after activation")
    }

    /// Method 2: Set AXFrontmost attribute on app element
    private func tryAXFrontmostActivation(
        app: MirageApplication,
        axWindow: AXUIElement?
    ) -> ActivationResult {
        let appElement = AXUIElementCreateApplication(app.id)

        // Set the application as frontmost
        let result = AXUIElementSetAttributeValue(
            appElement,
            kAXFrontmostAttribute as CFString,
            kCFBooleanTrue
        )

        if result != .success {
            return .failure(method: "AXFrontmost", error: "AXError \(result.rawValue)")
        }

        // Raise specific window if provided
        if let axWindow = axWindow {
            AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(axWindow, kAXMainAttribute as CFString, kCFBooleanTrue)
        }

        // Verify
        Thread.sleep(forTimeInterval: configuration.verificationTimeout)

        var frontmostRef: CFTypeRef?
        AXUIElementCopyAttributeValue(appElement, kAXFrontmostAttribute as CFString, &frontmostRef)

        if let isFrontmost = frontmostRef as? Bool, isFrontmost {
            return .success(method: "AXFrontmost")
        }

        // AX succeeded but verification uncertain - common on headless
        return .partialSuccess(method: "AXFrontmost", message: "Set succeeded but verification uncertain")
    }

    /// Method 3: Raise window and set as focused
    private func tryAXRaiseAndFocus(
        app: MirageApplication,
        axWindow: AXUIElement?
    ) -> ActivationResult {
        guard let axWindow = axWindow else {
            return .failure(method: "AXRaiseAndFocus", error: "No AXWindow provided")
        }

        let appElement = AXUIElementCreateApplication(app.id)

        // Raise the window
        let raiseResult = AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)

        // Set as focused window
        let focusResult = AXUIElementSetAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            axWindow
        )

        // Set as main window
        let mainResult = AXUIElementSetAttributeValue(
            axWindow,
            kAXMainAttribute as CFString,
            kCFBooleanTrue
        )

        if raiseResult == .success && (focusResult == .success || mainResult == .success) {
            return .success(method: "AXRaiseAndFocus")
        }

        if raiseResult == .success {
            return .partialSuccess(method: "AXRaiseAndFocus", message: "Raise succeeded, focus failed")
        }

        return .failure(method: "AXRaiseAndFocus", error: "Raise: \(raiseResult.rawValue), Focus: \(focusResult.rawValue)")
    }

    /// Method 4: AppleScript activation (most reliable on headless)
    private func tryAppleScriptActivation(app: MirageApplication) -> ActivationResult {
        let script: NSAppleScript

        // Prefer bundle identifier (more reliable)
        if let bundleID = app.bundleIdentifier {
            let source = """
            tell application id "\(bundleID)"
                activate
            end tell
            """
            guard let s = NSAppleScript(source: source) else {
                return .failure(method: "AppleScript", error: "Failed to create script")
            }
            script = s
        } else {
            // Fall back to name
            let escapedName = app.name.replacingOccurrences(of: "\"", with: "\\\"")
            let source = """
            tell application "\(escapedName)"
                activate
            end tell
            """
            guard let s = NSAppleScript(source: source) else {
                return .failure(method: "AppleScript", error: "Failed to create script")
            }
            script = s
        }

        var errorDict: NSDictionary?
        script.executeAndReturnError(&errorDict)

        if let error = errorDict {
            let errorMessage = error[NSAppleScript.errorMessage] as? String ?? "Unknown error"
            return .failure(method: "AppleScript", error: errorMessage)
        }

        // Verify activation
        Thread.sleep(forTimeInterval: configuration.verificationTimeout)

        if let runningApp = NSRunningApplication(processIdentifier: app.id), runningApp.isActive {
            return .success(method: "AppleScript")
        }

        // AppleScript doesn't always reflect in isActive on headless, consider partial success
        return .partialSuccess(method: "AppleScript", message: "Executed without error")
    }

    /// Method 5: NSWorkspace.open with activation configuration
    private func tryNSWorkspaceActivation(app: MirageApplication) -> ActivationResult {
        guard let bundleID = app.bundleIdentifier,
              let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return .failure(method: "NSWorkspace", error: "Cannot find app URL")
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.hidesOthers = false

        let semaphore = DispatchSemaphore(value: 0)
        var openError: Error?

        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, error in
            openError = error
            semaphore.signal()
        }

        let timeout = DispatchTime.now() + .milliseconds(500)
        if semaphore.wait(timeout: timeout) == .timedOut {
            return .failure(method: "NSWorkspace", error: "Timed out")
        }

        if let error = openError {
            return .failure(method: "NSWorkspace", error: error.localizedDescription)
        }

        return .success(method: "NSWorkspace")
    }
}

// MARK: - Headless Detection

public extension WindowActivator {
    /// Returns true if running without any connected displays
    static var isHeadless: Bool {
        NSScreen.screens.isEmpty
    }

    /// Creates a WindowActivator with configuration appropriate for the current display state
    static func forCurrentEnvironment() -> WindowActivator {
        WindowActivator(configuration: isHeadless ? .headless : .default)
    }
}
#endif
