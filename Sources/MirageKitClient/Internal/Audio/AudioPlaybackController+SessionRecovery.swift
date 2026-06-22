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
                let interruptionType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                let interruptionOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                Task { @MainActor [weak self, reason, interruptionType, interruptionOptions] in
                    guard let self else { return }
                    await self.handleAudioSessionNotification(
                        reason: reason,
                        interruptionType: interruptionType,
                        interruptionOptions: interruptionOptions
                    )
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

    /// Applies platform-specific interruption semantics before rebuilding playback.
    func handleAudioSessionNotification(
        reason: String,
        interruptionType: UInt?,
        interruptionOptions: UInt
    ) async {
        if let interruptionType,
           let type = AVAudioSession.InterruptionType(rawValue: interruptionType) {
            switch type {
            case .began:
                await suspendPlaybackForAudioSessionInterruption(reason: reason)
            case .ended:
                await recoverPlaybackAfterAudioSessionReset(
                    reason: reason,
                    shouldResume: true
                )
            @unknown default:
                await recoverPlaybackAfterAudioSessionReset(reason: "\(reason)-unknown-\(interruptionType)")
            }
            return
        }

        await recoverPlaybackAfterAudioSessionReset(reason: reason)
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

        await recoverPlaybackAfterAudioSessionReset(reason: "route-change-\(reason.rawValue)")
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
