//
//  MirageAudioSessionCoordinator.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/13/26.
//
//  Coordinates shared AVAudioSession ownership across client audio features.
//

#if os(iOS) || os(visionOS)
import AVFAudio
import Foundation
import MirageKit

@MainActor
final class MirageAudioSessionCoordinator {
    static let shared = MirageAudioSessionCoordinator()

    private enum Claim: Hashable {
        case playback
        case dictation
    }

    private struct Configuration: Equatable {
        let category: AVAudioSession.Category
        let mode: AVAudioSession.Mode
        let options: AVAudioSession.CategoryOptions

        static let playback = Configuration(
            category: .playback,
            mode: .default,
            options: [.mixWithOthers]
        )

        static let dictation = Configuration(
            category: .playAndRecord,
            mode: .measurement,
            options: [.mixWithOthers, .defaultToSpeaker]
        )
    }

    private var activeClaims: Set<Claim> = []
    private var activeConfiguration: Configuration?
    private var sessionIsActive = false

    private init() {}

    func activatePlaybackIfNeeded() throws {
        activeClaims.insert(.playback)
        try reconcileAudioSession()
    }

    func deactivatePlaybackIfNeeded() {
        activeClaims.remove(.playback)
        reconcileAudioSessionIgnoringErrors(reason: "playback deactivation")
    }

    func activateDictationIfNeeded() throws {
        activeClaims.insert(.dictation)
        try reconcileAudioSession()
    }

    func deactivateDictationIfNeeded() {
        activeClaims.remove(.dictation)
        reconcileAudioSessionIgnoringErrors(reason: "dictation deactivation")
    }

    private func reconcileAudioSession() throws {
        let session = AVAudioSession.sharedInstance()

        guard let preferredConfiguration else {
            if sessionIsActive {
                try session.setActive(false, options: .notifyOthersOnDeactivation)
            }
            activeConfiguration = nil
            sessionIsActive = false
            return
        }

        let needsReconfiguration = activeConfiguration != preferredConfiguration
            || session.category != preferredConfiguration.category
            || session.mode != preferredConfiguration.mode
            || session.categoryOptions != preferredConfiguration.options
        if needsReconfiguration {
            try session.setCategory(
                preferredConfiguration.category,
                mode: preferredConfiguration.mode,
                options: preferredConfiguration.options
            )
            activeConfiguration = preferredConfiguration
        }

        if !sessionIsActive {
            try session.setActive(true, options: [])
            sessionIsActive = true
        }
    }

    private var preferredConfiguration: Configuration? {
        if activeClaims.contains(.dictation) { return .dictation }
        if activeClaims.contains(.playback) { return .playback }
        return nil
    }

    private func reconcileAudioSessionIgnoringErrors(reason: String) {
        do {
            try reconcileAudioSession()
        } catch {
            MirageLogger.error(.client, error: error, message: "Audio session reconciliation failed during \(reason): ")
        }
    }
}
#endif
