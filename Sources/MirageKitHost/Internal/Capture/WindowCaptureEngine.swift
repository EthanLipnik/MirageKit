//
//  WindowCaptureEngine.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/2/26.
//

import CoreMedia
import CoreVideo
import Foundation
import os
import MirageKit

#if os(macOS)
import AppKit
import CoreGraphics
import ScreenCaptureKit

actor WindowCaptureEngine {
    var stream: SCStream?
    var streamOutput: CaptureStreamOutput?
    let configuration: MirageEncoderConfiguration
    let latencyMode: MirageStreamLatencyMode
    var currentFrameRate: Int
    let usesDisplayRefreshCadence: Bool
    var currentDisplayRefreshRate: Int?
    var admissionDropper: (@Sendable () -> Bool)?
    var pendingKeyframeRequest = false
    var isCapturing = false
    var isRestarting = false
    var capturedFrameHandler: (@Sendable (CapturedFrame) -> Void)?
    var dimensionChangeHandler: (@Sendable (Int, Int) -> Void)?
    var captureMode: CaptureMode?
    var captureSessionConfig: CaptureSessionConfiguration?

    // Track current dimensions to detect changes
    var currentWidth: Int = 0
    var currentHeight: Int = 0
    var currentScaleFactor: CGFloat = 1.0
    var outputScale: CGFloat = 1.0
    var useBestCaptureResolution: Bool = true
    var useExplicitCaptureDimensions: Bool = true
    var contentFilter: SCContentFilter?
    var lastRestartTime: CFAbsoluteTime = 0
    let restartCooldown: CFAbsoluteTime = 3.0

    init(
        configuration: MirageEncoderConfiguration,
        latencyMode: MirageStreamLatencyMode = .balanced,
        captureFrameRate: Int? = nil,
        usesDisplayRefreshCadence: Bool = false
    ) {
        self.configuration = configuration
        self.latencyMode = latencyMode
        currentFrameRate = max(1, captureFrameRate ?? configuration.targetFrameRate)
        self.usesDisplayRefreshCadence = usesDisplayRefreshCadence
    }

    enum CaptureMode {
        case window
        case display
    }

    struct CaptureSessionConfiguration {
        let windowID: WindowID?
        let applicationPID: pid_t?
        let displayID: CGDirectDisplayID
        let window: SCWindow?
        let application: SCRunningApplication?
        let display: SCDisplay
        let knownScaleFactor: CGFloat?
        let outputScale: CGFloat
        let resolution: CGSize?
        let showsCursor: Bool
    }

    func setAdmissionDropper(_ dropper: (@Sendable () -> Bool)?) {
        admissionDropper = dropper
    }
}

#endif
