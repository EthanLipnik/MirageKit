//
//  StreamPacketSender+Pacing.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/9/26.
//

import Foundation
import MirageKit

#if os(macOS)

extension StreamPacketSender {
    /// Waits for packet-pacer tokens before submitting a fragment to the media transport.
    ///
    /// The pacer honors sender-local deadlines for non-keyframes so freshness recovery can drop stale work instead
    /// of sleeping past the frame's useful lifetime.
    func paceIfNeeded(
        packetBytes: Int,
        isKeyframeBurst: Bool,
        totalFragments: Int,
        targetFrameRate: Int,
        pacingOverride: PacingOverride?,
        sendDeadline: CFAbsoluteTime?
    ) async -> PacketPacingResult {
        let targetFrameIntervalMs = 1000.0 / Double(max(1, targetFrameRate))
        guard let parameters = Self.packetPacingParameters(
            targetRateBps: pacerRateBps,
            packetBytes: packetBytes,
            isKeyframeBurst: isKeyframeBurst,
            totalFragments: totalFragments,
            targetFrameIntervalMs: targetFrameIntervalMs,
            pacingOverride: pacingOverride
        ) else {
            return PacketPacingResult(
                sleepSample: PacketPacingSleepSample(totalMs: 0, maxMs: 0),
                didMissDeadline: false
            )
        }

        let bytesPerSecond = parameters.bytesPerSecond
        let bytesPerMillisecond = max(1.0, bytesPerSecond / 1000.0)
        let burstBytes = parameters.burstBytes
        refillPacketPacerTokens(
            now: CFAbsoluteTimeGetCurrent(),
            bytesPerSecond: bytesPerSecond,
            burstBytes: burstBytes
        )

        var sleepTotalMs = 0
        var sleepMaxMs = 0
        while true {
            let beforeSleep = CFAbsoluteTimeGetCurrent()
            if let sendDeadline, beforeSleep >= sendDeadline {
                return PacketPacingResult(
                    sleepSample: PacketPacingSleepSample(totalMs: sleepTotalMs, maxMs: sleepMaxMs),
                    didMissDeadline: true
                )
            }
            let sleepMs = Self.packetPacerSleepMilliseconds(
                tokensBeforeSend: pacerTokensBytes,
                packetBytes: packetBytes,
                bytesPerMillisecond: bytesPerMillisecond
            )
            guard sleepMs > 0 else { break }
            if let sendDeadline, beforeSleep + (Double(sleepMs) / 1000.0) >= sendDeadline {
                break
            }

            do {
                try await Task.sleep(for: .milliseconds(Int64(sleepMs)))
            } catch {
                return PacketPacingResult(
                    sleepSample: PacketPacingSleepSample(totalMs: sleepTotalMs, maxMs: sleepMaxMs),
                    didMissDeadline: true
                )
            }
            recordPacketPacerSleep(PacketPacingSleepSample(totalMs: sleepMs, maxMs: sleepMs))
            sleepTotalMs += sleepMs
            sleepMaxMs = max(sleepMaxMs, sleepMs)

            let now = CFAbsoluteTimeGetCurrent()
            refillPacketPacerTokens(
                now: now,
                bytesPerSecond: bytesPerSecond,
                burstBytes: burstBytes
            )
            logPacketPacingIfNeeded(now: now)
        }

        pacerTokensBytes -= Double(packetBytes)
        return PacketPacingResult(
            sleepSample: PacketPacingSleepSample(
                totalMs: sleepTotalMs,
                maxMs: sleepMaxMs
            ),
            didMissDeadline: false
        )
    }

    /// Resets packet pacer token and sleep counters.
    func resetPacketPacerState(now: CFAbsoluteTime) {
        pacerTokensBytes = 0
        pacerLastRefillTime = 0
        resetPacketPacerTelemetryCounters()
        pacerLastLogTime = now
    }

    /// Refills pacing tokens based on elapsed time and clamps the token bucket.
    func refillPacketPacerTokens(
        now: CFAbsoluteTime,
        bytesPerSecond: Double,
        burstBytes: Double
    ) {
        if pacerLastRefillTime == 0 {
            pacerLastRefillTime = now
            pacerTokensBytes = burstBytes
            return
        }

        let elapsed = max(0.0, now - pacerLastRefillTime)
        pacerLastRefillTime = now
        pacerTokensBytes = min(
            burstBytes,
            max(-burstBytes, pacerTokensBytes + elapsed * bytesPerSecond)
        )
    }

    /// Emits steady-state packet pacing diagnostics when enabled.
    func logPacketPacingIfNeeded(now: CFAbsoluteTime) {
        guard MirageSteadyStateDiagnostics.isEnabled else { return }
        guard MirageLogger.isEnabled(.network) else { return }
        guard pacerSleepPacketCount > 0 else { return }
        guard pacerLastLogTime == 0 || now - pacerLastLogTime >= Self.packetPacerLogIntervalSeconds else { return }

        MirageLogger.network(
            "Packet pacer: sleeps=\(pacerSleepPacketCount), totalMs=\(pacerSleepTotalMs), maxMs=\(pacerSleepMaxMs)"
        )
        pacerLastLogTime = now
    }
}

#endif
