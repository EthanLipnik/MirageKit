//
//  HEVCEncoder+Slots.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  HEVC encoder extensions.
//

import CoreMedia
import Foundation
import VideoToolbox
import MirageKit

#if os(macOS)
import ScreenCaptureKit

extension HEVCEncoder {
    nonisolated func reserveEncoderSlot() -> Bool {
        encoderInFlightLock.lock()
        defer { encoderInFlightLock.unlock() }
        guard encoderInFlightCount < encoderInFlightLimit else { return false }
        encoderInFlightCount += 1
        return true
    }

    nonisolated func releaseEncoderSlot() {
        encoderInFlightLock.lock()
        encoderInFlightCount = max(0, encoderInFlightCount - 1)
        encoderInFlightLock.unlock()
    }
}

#endif
