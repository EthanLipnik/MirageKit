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
    func paceIfNeeded(
        packetBytes: Int,
        isKeyframeBurst: Bool,
        totalFragments: Int,
        targetFrameRate: Int,
        pacingOverride: PacingOverride?
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
                sleepSample: PacketPacingSleepSample(totalMs: 0, maxMs: 0)
            )
        }

        let now = CFAbsoluteTimeGetCurrent()
        let pressurePacingActive = awdlPressurePacingIsActive(now: now)
        let bytesPerSecond = parameters.bytesPerSecond
        let bytesPerMillisecond = max(1.0, bytesPerSecond / 1000.0)
        let burstBytes = pressurePacingActive ?
            min(parameters.burstBytes, Double(max(packetBytes, maxPayloadSize))) :
            parameters.burstBytes
        refillPacketPacerTokens(
            now: now,
            bytesPerSecond: bytesPerSecond,
            burstBytes: burstBytes
        )

        var sleepTotalMs = 0
        var sleepMaxMs = 0
        while true {
            let sleepMs = Self.packetPacerSleepMilliseconds(
                tokensBeforeSend: pacerTokensBytes,
                packetBytes: packetBytes,
                bytesPerMillisecond: bytesPerMillisecond
            )
            guard sleepMs > 0 else { break }

            do {
                try await Task.sleep(for: .milliseconds(Int64(sleepMs)))
            } catch {
                return PacketPacingResult(
                    sleepSample: PacketPacingSleepSample(totalMs: sleepTotalMs, maxMs: sleepMaxMs)
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
            )
        )
    }

    /// Resets packet pacer token and sleep counters.
    func resetPacketPacerState(now: CFAbsoluteTime) {
        pacerTokensBytes = 0
        pacerLastRefillTime = 0
        resetPacketPacerTelemetryCounters()
        pacerLastLogTime = now
    }

    /// Returns true while receiver feedback asks AWDL media pacing to avoid multi-packet bursts.
    func awdlPressurePacingIsActive(now: CFAbsoluteTime) -> Bool {
        guard awdlPressurePacingDeadline > 0 else { return false }
        guard now < awdlPressurePacingDeadline else {
            awdlPressurePacingDeadline = 0
            awdlPressurePacingReason = nil
            return false
        }
        return true
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
