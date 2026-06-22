import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageKit
import MirageMedia
import MirageWire
//
//  MirageVideoPlayoutBufferTypes.swift
//  MirageKitClientPresentation
//
//  Created by Ethan Lipnik on 6/5/26.
//

extension MirageVideoPlayoutBuffer {
    package struct TrimResult: Equatable, Sendable {
        package var overwrittenPendingFrames: Int = 0
        package var smoothestQueueDrops: Int = 0
        package var smoothestDepthDrops: Int = 0
        package var smoothestAgeDrops: Int = 0
        package var smoothestDropsUnder100ms: Int = 0
        package var smoothestDroppedFrameAgeMaxMs: Double = 0
        package var smoothestDisplayDebtDrops: Int = 0
        package var smoothestFifoResetCount: Int = 0
        package var lateFrameDrops: Int = 0
        package var coalescedFrames: Int = 0

        package static let empty = TrimResult()

        package mutating func absorb(_ other: TrimResult) {
            overwrittenPendingFrames += other.overwrittenPendingFrames
            smoothestQueueDrops += other.smoothestQueueDrops
            smoothestDepthDrops += other.smoothestDepthDrops
            smoothestAgeDrops += other.smoothestAgeDrops
            smoothestDropsUnder100ms += other.smoothestDropsUnder100ms
            smoothestDroppedFrameAgeMaxMs = max(smoothestDroppedFrameAgeMaxMs, other.smoothestDroppedFrameAgeMaxMs)
            smoothestDisplayDebtDrops += other.smoothestDisplayDebtDrops
            smoothestFifoResetCount += other.smoothestFifoResetCount
            lateFrameDrops += other.lateFrameDrops
            coalescedFrames += other.coalescedFrames
        }

        package mutating func recordLowestLatencyDrop(count: Int) {
            guard count > 0 else { return }
            overwrittenPendingFrames += count
            coalescedFrames += count
        }

        package mutating func recordSmoothestDepthDrop(ageMs: Double) {
            smoothestQueueDrops += 1
            smoothestDepthDrops += 1
            recordSmoothestDroppedFrameAge(ageMs)
        }

        package mutating func recordSmoothestDisplayDebtDrop(ageMs: Double) {
            smoothestQueueDrops += 1
            smoothestDepthDrops += 1
            smoothestDisplayDebtDrops += 1
            recordSmoothestDroppedFrameAge(ageMs)
        }

        package mutating func recordSmoothestAgeDrop(ageMs: Double) {
            smoothestQueueDrops += 1
            smoothestAgeDrops += 1
            recordSmoothestDroppedFrameAge(ageMs)
        }

        package mutating func recordSmoothestFifoReset() {
            smoothestFifoResetCount += 1
        }

        private mutating func recordSmoothestDroppedFrameAge(_ ageMs: Double) {
            smoothestDroppedFrameAgeMaxMs = max(smoothestDroppedFrameAgeMaxMs, ageMs)
            if ageMs > 0, ageMs < 100 {
                smoothestDropsUnder100ms += 1
            }
        }
    }

    package struct Selection: Sendable {
        package let frame: MirageRenderFrame?
        package let trimResult: TrimResult
        package let selectedFrameNumber: UInt32?
    }

    enum DelayIncreaseReason {
        case underflow
        case frameAfterEmptyTick
        case burst
    }
}
