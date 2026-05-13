//
//  MirageHostService+QualityTestSupport.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/10/26.
//
//  Host quality-test send support types.
//

import Foundation
import Loom

#if os(macOS)
/// Thread-safe accounting for packets queued during one host quality-test stage.
final class QualityTestStageSendState: @unchecked Sendable {
    private let lock = NSLock()
    private let queueProfile: LoomQueuedUnreliableSendProfile
    private var outstandingPackets = 0
    private var outstandingBytes = 0
    private var sendErrorDescription: String?

    init(queueProfile: LoomQueuedUnreliableSendProfile) {
        self.queueProfile = queueProfile
    }

    /// Attempts to reserve queue capacity for one packet before submitting it to Loom.
    func tryReserve(packetBytes: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let canReserve = MirageHostService.qualityTestCanEnqueuePacket(
            outstandingPackets: outstandingPackets,
            outstandingBytes: outstandingBytes,
            packetBytes: packetBytes,
            profile: queueProfile
        )
        if canReserve {
            outstandingPackets += 1
            outstandingBytes += packetBytes
        }
        return canReserve
    }

    /// Marks one queued packet as completed and records the first send error, if any.
    func completePacket(packetBytes: Int, error: Error?) {
        lock.lock()
        defer { lock.unlock() }
        outstandingPackets = max(0, outstandingPackets - 1)
        outstandingBytes = max(0, outstandingBytes - packetBytes)
        if sendErrorDescription == nil, let error {
            sendErrorDescription = String(describing: error)
        }
    }

    var errorDescription: String? {
        lock.lock()
        defer { lock.unlock() }
        return sendErrorDescription
    }

    var outstandingPacketCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return outstandingPackets
    }
}

/// Token-bucket pacer that spaces quality-test packets to match the stage bitrate.
struct QualityTestPacketPacer {
    let targetRateBps: Int
    private var tokensBytes: Double = 0
    private var lastRefillTime: CFAbsoluteTime = 0

    init(targetRateBps: Int) {
        self.targetRateBps = targetRateBps
    }

    /// Sleeps as needed before the next packet so replay stages mimic media pacing.
    mutating func paceNextPacket(
        packetBytes: Int,
        isKeyframeBurst: Bool,
        totalFragments: Int
    ) async {
        guard let parameters = StreamPacketSender.packetPacingParameters(
            targetRateBps: targetRateBps,
            packetBytes: packetBytes,
            isKeyframeBurst: isKeyframeBurst,
            totalFragments: totalFragments,
            pacingOverride: nil
        ) else {
            return
        }

        let initialNow = CFAbsoluteTimeGetCurrent()
        refill(
            now: initialNow,
            bytesPerSecond: parameters.bytesPerSecond,
            burstBytes: parameters.burstBytes
        )
        let sleepMs = StreamPacketSender.packetPacerSleepMilliseconds(
            tokensBeforeSend: tokensBytes,
            packetBytes: packetBytes,
            bytesPerMillisecond: parameters.bytesPerSecond / 1000.0
        )
        if sleepMs > 0 {
            do {
                try await Task.sleep(for: .milliseconds(sleepMs))
            } catch {
                return
            }
            refill(
                now: CFAbsoluteTimeGetCurrent(),
                bytesPerSecond: parameters.bytesPerSecond,
                burstBytes: parameters.burstBytes
            )
        }

        tokensBytes -= Double(packetBytes)
    }

    private mutating func refill(
        now: CFAbsoluteTime,
        bytesPerSecond: Double,
        burstBytes: Double
    ) {
        if lastRefillTime == 0 {
            lastRefillTime = now
            tokensBytes = burstBytes
            return
        }

        let elapsed = max(0.0, now - lastRefillTime)
        lastRefillTime = now
        tokensBytes = min(
            burstBytes,
            max(-burstBytes, tokensBytes + elapsed * bytesPerSecond)
        )
    }
}

/// Host-side send counters reported back for one quality-test stage.
struct QualityTestStageSendMetrics {
    /// Timestamp captured immediately before the first stage packet is queued.
    let startedAtTimestampNs: UInt64
    /// Timestamp for the end of the fixed measurement window.
    let measurementEndedAtTimestampNs: UInt64
    /// Number of packets queued for the stage.
    let sentPacketCount: Int
    /// Number of payload bytes queued for the stage, excluding Mirage test headers.
    let sentPayloadBytes: Int
    /// Whether the host missed the expected delivery window for the stage.
    let deliveryWindowMissed: Bool
}
#endif
