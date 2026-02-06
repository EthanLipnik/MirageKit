//
//  SCKWrappers.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/5/26.
//

import Foundation
import MirageKit
#if os(macOS)
import ScreenCaptureKit

/// Wrapper to send SCWindow across actor boundaries safely
/// SCWindow is a ScreenCaptureKit type that's internally thread-safe
struct SCWindowWrapper: @unchecked Sendable {
    let window: SCWindow
}

/// Wrapper to send SCRunningApplication across actor boundaries safely
struct SCApplicationWrapper: @unchecked Sendable {
    let application: SCRunningApplication
}

/// Wrapper to send SCDisplay across actor boundaries safely
struct SCDisplayWrapper: @unchecked Sendable {
    let display: SCDisplay
}

#endif
