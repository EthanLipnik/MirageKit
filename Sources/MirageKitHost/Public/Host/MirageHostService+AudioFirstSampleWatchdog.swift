//
//  MirageHostService+AudioFirstSampleWatchdog.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/12/26.
//
//  Host audio first-sample recovery watchdog.
//

import Foundation
import MirageKit

#if os(macOS)

private let hostAudioFirstSampleTimeout: Duration = .seconds(5)

@MainActor
extension MirageHostService {
    /// Arms a watchdog that restarts capture once if an enabled audio pipeline never receives audio.
    func scheduleAudioFirstSampleWatchdog(clientID: UUID, streamID: StreamID) {
        cancelAudioFirstSampleWatchdog(for: clientID)
        let activationTime = CFAbsoluteTimeGetCurrent()
        audioFirstSampleWatchdogsByClientID[clientID] = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: hostAudioFirstSampleTimeout)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.handleAudioFirstSampleWatchdogTimeout(
                clientID: clientID,
                streamID: streamID,
                activationTime: activationTime
            )
        }
    }

    /// Cancels any pending first-sample watchdog for a client.
    func cancelAudioFirstSampleWatchdog(for clientID: UUID) {
        audioFirstSampleWatchdogsByClientID.removeValue(forKey: clientID)?.cancel()
    }

    /// Records audio capture progress and clears recovery state once samples arrive.
    func recordCapturedAudioSample(clientID: UUID, streamID: StreamID) {
        audioLastSampleTimeByClientID[clientID] = CFAbsoluteTimeGetCurrent()
        if audioFirstSampleWatchdogsByClientID[clientID] != nil {
            MirageLogger.host("First captured audio sample observed for client \(clientID), stream \(streamID)")
        }
        cancelAudioFirstSampleWatchdog(for: clientID)
        audioFirstSampleRetryAttemptedByClientID.remove(clientID)
    }

    /// Restarts the first-sample watchdog after the source capture is known to be running.
    func refreshAudioFirstSampleWatchdogIfNeeded(clientID: UUID, streamID: StreamID) {
        guard audioConfigurationByClientID[clientID]?.enabled == true,
              audioPipelinesByClientID[clientID] != nil,
              audioSourceStreamByClientID[clientID] == streamID,
              audioLastSampleTimeByClientID[clientID] == nil else {
            return
        }
        scheduleAudioFirstSampleWatchdog(clientID: clientID, streamID: streamID)
    }

    private func handleAudioFirstSampleWatchdogTimeout(
        clientID: UUID,
        streamID: StreamID,
        activationTime: CFAbsoluteTime
    )
    async {
        audioFirstSampleWatchdogsByClientID.removeValue(forKey: clientID)
        let hasMatchingActiveAudioPipeline =
            audioConfigurationByClientID[clientID]?.enabled == true &&
            audioPipelinesByClientID[clientID] != nil &&
            audioSourceStreamByClientID[clientID] == streamID
        guard hasMatchingActiveAudioPipeline else {
            return
        }
        if let lastSampleTime = audioLastSampleTimeByClientID[clientID],
           lastSampleTime >= activationTime {
            return
        }

        if !audioFirstSampleRetryAttemptedByClientID.contains(clientID) {
            audioFirstSampleRetryAttemptedByClientID.insert(clientID)
            MirageLogger.host(
                "Audio capture produced no first sample for client \(clientID), stream \(streamID); " +
                    "restarting capture once with audio enabled"
            )
            let restarted = await restartAudioSourceCaptureForRecovery(
                clientID: clientID,
                streamID: streamID,
                reason: "audio_first_sample_timeout"
            )
            if !restarted {
                MirageLogger.host(
                    "Audio first-sample recovery found no restartable capture source for client \(clientID), " +
                        "stream \(streamID)"
                )
            }
            scheduleAudioFirstSampleWatchdog(clientID: clientID, streamID: streamID)
            return
        }

        MirageLogger.host(
            "Audio capture produced no first sample after retry for client \(clientID), stream \(streamID); " +
                "stopping audio stream"
        )
        await stopAudioPipeline(for: clientID, reason: .error)
        await closeAudioTransportIfNeeded(for: clientID)
    }
}

#endif
