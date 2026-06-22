//
//  MirageHostService+AudioFirstSampleWatchdog.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/12/26.
//
//  Host audio first-sample recovery watchdog.
//

import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageKit
import MirageKitClientPresentation
import MirageMedia
import MirageWire
import Foundation

#if os(macOS)

private let hostAudioFirstSampleTimeout: Duration = .seconds(2)

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
            await streamsByID[streamID]?.restartCaptureForAudioRecovery(reason: "audio_first_sample_timeout")
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
