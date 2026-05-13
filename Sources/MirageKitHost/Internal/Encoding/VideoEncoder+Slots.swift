//
//  VideoEncoder+Slots.swift
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

extension VideoEncoder {
    nonisolated func reserveEncoderSlot() -> Bool {
        encoderInFlightLock.lock()
        defer { encoderInFlightLock.unlock() }
        guard encoderInFlightCount < encoderInFlightLimit else { return false }
        encoderInFlightCount += 1
        return true
    }

    nonisolated func releaseEncoderSlot() {
        encoderInFlightLock.lock()
        defer { encoderInFlightLock.unlock() }
        encoderInFlightCount = max(0, encoderInFlightCount - 1)
    }

    nonisolated func resetEncoderSlots() {
        encoderInFlightLock.lock()
        defer { encoderInFlightLock.unlock() }
        encoderInFlightCount = 0
    }

    nonisolated var encoderInFlightSnapshot: Int {
        encoderInFlightLock.lock()
        defer { encoderInFlightLock.unlock() }
        return encoderInFlightCount
    }
}

#endif
