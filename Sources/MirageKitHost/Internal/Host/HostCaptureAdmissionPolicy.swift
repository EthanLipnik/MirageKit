//
//  HostCaptureAdmissionPolicy.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 6/1/26.
//

import Foundation
import MirageKit

#if os(macOS)
struct HostCaptureAdmissionPolicy: Sendable, Equatable {
    static func shouldDropCapturedFrame(
        latencyMode: MirageStreamLatencyMode,
        hostBufferingPolicy: MirageHostBufferingPolicy,
        pendingFrameCount: Int,
        frameCapacity: Int,
        backpressureActive: Bool
    ) -> Bool {
        let capacity = max(1, frameCapacity)
        let pending = max(0, pendingFrameCount)

        if backpressureActive {
            return pending >= max(1, capacity - 1)
        }

        if latencyMode == .lowestLatency, hostBufferingPolicy == .freshestFrame {
            return false
        }

        return pending >= capacity
    }
}
#endif
