//
//  WindowCaptureEngine+Frames.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Frame handling helpers.
//

import CoreMedia
import CoreVideo
import Foundation
import os
import MirageKit

#if os(macOS)
import AppKit
import ScreenCaptureKit

extension WindowCaptureEngine {
    func handleFrame(_ frame: CapturedFrame) {
        capturedFrameHandler?(frame)
    }

    func markKeyframeRequested() {
        pendingKeyframeRequest = true
    }

    func consumePendingKeyframeRequest() async -> Bool {
        if pendingKeyframeRequest {
            pendingKeyframeRequest = false
            return true
        }
        return false
    }
}

#endif
