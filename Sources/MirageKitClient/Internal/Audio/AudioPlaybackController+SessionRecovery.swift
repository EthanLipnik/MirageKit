//
//  AudioPlaybackController+SessionRecovery.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/10/26.
//
//  Platform audio-session recovery observers.
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
import AVFAudio
import Foundation

#if os(iOS) || os(visionOS)
@MainActor
extension AudioPlaybackController {
    /// Registers AVAudioSession notifications that require rebuilding the playback graph.
    func installAudioSessionRecoveryObservers() {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        let names: [Notification.Name] = [
            AVAudioSession.interruptionNotification,
            AVAudioSession.mediaServicesWereLostNotification,
            AVAudioSession.mediaServicesWereResetNotification,
        ]
        audioSessionObserverTokens = names.map { name in
            center.addObserver(forName: name, object: session, queue: nil) { [weak self] notification in
                let reason = notification.name.rawValue
                Task { @MainActor [weak self, reason] in
                    guard let self else { return }
                    await self.handleAudioSessionRecovery(reason: reason)
                }
            }
        }
        let routeToken = center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: session,
            queue: nil
        ) { [weak self] notification in
            let reasonValue = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            Task { @MainActor [weak self, reasonValue] in
                guard let self else { return }
                await self.handleAudioRouteChange(reasonValue: reasonValue)
            }
        }
        audioSessionObserverTokens.append(routeToken)
    }

    /// Removes registered AVAudioSession observer tokens.
    nonisolated func removeAudioSessionRecoveryObservers() {
        let center = NotificationCenter.default
        for token in audioSessionObserverTokens {
            center.removeObserver(token)
        }
        audioSessionObserverTokens.removeAll()
    }

    /// Resets playback after an audio-session interruption or media-services reset.
    func handleAudioSessionRecovery(reason: String) async {
        MirageLogger.client("Audio playback session recovery: \(reason)")
        await reset()
    }

    /// Handles route changes that alter the output channel count.
    func handleAudioRouteChange(reasonValue: UInt?) async {
        guard let reasonValue,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue),
              Self.shouldRecoverPlaybackForRouteChange(reason) else {
            return
        }
        guard isConfigured, configuredOutputChannelCount > 0 else { return }
        let currentOutputChannelCount = resolvedOutputChannelCount(fallback: configuredOutputChannelCount)
        guard currentOutputChannelCount > 0,
              currentOutputChannelCount != configuredOutputChannelCount else {
            return
        }

        await handleAudioSessionRecovery(reason: "route-change-\(reason.rawValue)")
    }

    /// Returns true when an AVAudioSession route-change reason can invalidate the configured output graph.
    nonisolated static func shouldRecoverPlaybackForRouteChange(
        _ reason: AVAudioSession.RouteChangeReason
    ) -> Bool {
        switch reason {
        case .oldDeviceUnavailable, .newDeviceAvailable, .routeConfigurationChange:
            return true
        case .unknown, .categoryChange, .override, .wakeFromSleep, .noSuitableRouteForCategory:
            return false
        @unknown default:
            return false
        }
    }
}
#endif
