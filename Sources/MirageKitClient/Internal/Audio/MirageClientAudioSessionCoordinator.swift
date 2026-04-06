//
//  MirageClientAudioSessionCoordinator.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/31/26.
//
//  Shared audio-session arbitration for playback and dictation on iOS and visionOS.
//

import Foundation
import MirageKit

#if os(iOS) || os(visionOS)
import AVFAudio
import UIKit
#endif

internal enum MirageClientAudioSessionConfiguration: Equatable {
    case playback
    case dictation
}

internal protocol MirageClientAudioSessionDriving {
    var isApplicationActive: Bool { get }
    func activate(_ configuration: MirageClientAudioSessionConfiguration) throws
    func deactivate() throws
}

@MainActor
internal final class MirageClientAudioSessionCoordinator {
    static let shared = MirageClientAudioSessionCoordinator()

    private let driver: any MirageClientAudioSessionDriving
    private var playbackLeaseCount = 0
    private var dictationLeaseCount = 0
    private var currentConfiguration: MirageClientAudioSessionConfiguration?
    private var activationFailureCount = 0
    private var activationBackoffUntil: ContinuousClock.Instant?
    private var loggedInactiveDeferral = false

    private static let maxActivationRetries = 3
    private static let activationBackoffs: [Duration] = [
        .milliseconds(100),
        .milliseconds(500),
        .seconds(2),
    ]

    init(driver: any MirageClientAudioSessionDriving = MirageSystemAudioSessionDriver()) {
        self.driver = driver
    }

    func requestPlaybackSession() -> Bool {
        playbackLeaseCount += 1
        let _ = refreshSessionIfNeeded()
        let isActive = currentConfiguration != nil
        if !isActive {
            playbackLeaseCount -= 1
        }
        return isActive
    }

    func releasePlaybackSession() {
        guard playbackLeaseCount > 0 else { return }
        playbackLeaseCount -= 1
        _ = refreshSessionIfNeeded()
    }

    func requestDictationSession() -> Bool {
        dictationLeaseCount += 1
        let _ = refreshSessionIfNeeded()
        let isActive = currentConfiguration == .dictation
        if !isActive {
            dictationLeaseCount -= 1
        }
        return isActive
    }

    func releaseDictationSession() {
        guard dictationLeaseCount > 0 else { return }
        dictationLeaseCount -= 1
        _ = refreshSessionIfNeeded()
    }

    #if DEBUG
    func resetForTesting() {
        playbackLeaseCount = 0
        dictationLeaseCount = 0
        currentConfiguration = nil
        activationFailureCount = 0
        activationBackoffUntil = nil
        loggedInactiveDeferral = false
    }
    #endif

    private var desiredConfiguration: MirageClientAudioSessionConfiguration? {
        if dictationLeaseCount > 0 {
            return .dictation
        }
        if playbackLeaseCount > 0 {
            return .playback
        }
        return nil
    }

    private func refreshSessionIfNeeded() -> Bool {
        guard let desiredConfiguration else {
            deactivateIfNeeded()
            return false
        }

        guard driver.isApplicationActive else {
            if !loggedInactiveDeferral {
                MirageLogger.client("Deferring shared audio session activation until app becomes active")
                loggedInactiveDeferral = true
            }
            return currentConfiguration != nil
        }

        loggedInactiveDeferral = false

        if currentConfiguration == desiredConfiguration {
            return true
        }

        if let activationBackoffUntil, ContinuousClock.now < activationBackoffUntil {
            return currentConfiguration != nil
        }

        do {
            try driver.activate(desiredConfiguration)
            currentConfiguration = desiredConfiguration
            activationFailureCount = 0
            activationBackoffUntil = nil
            return true
        } catch {
            if shouldSuppressActivationError(error) {
                activationFailureCount += 1
                if activationFailureCount <= Self.maxActivationRetries {
                    let backoffIndex = min(activationFailureCount - 1, Self.activationBackoffs.count - 1)
                    activationBackoffUntil = .now + Self.activationBackoffs[backoffIndex]
                    MirageLogger.debug(
                        .client,
                        "Shared audio session activation deferred (attempt \(activationFailureCount)/\(Self.maxActivationRetries)): \(error)"
                    )
                } else if activationFailureCount == Self.maxActivationRetries + 1 {
                    MirageLogger.client(
                        "Shared audio session activation failed after \(Self.maxActivationRetries) attempts; waiting for app to become active"
                    )
                }
                return currentConfiguration != nil
            }

            MirageLogger.error(.client, error: error, message: "Shared audio session setup failed: ")
            return currentConfiguration != nil
        }
    }

    private func deactivateIfNeeded() {
        guard currentConfiguration != nil else { return }
        currentConfiguration = nil
        activationFailureCount = 0
        activationBackoffUntil = nil
        loggedInactiveDeferral = false
        try? driver.deactivate()
    }

    private func shouldSuppressActivationError(_ error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == NSOSStatusErrorDomain
            || nsError.domain == "com.apple.coreaudio.avfaudio" else {
            return false
        }

        var deferredCodes: Set<Int> = [
            1836282486, // 'msrv': media services failed
            561210739, // '!ses': session unavailable while mediaserverd is recovering
            561017449, // '!ini': session not initialized
            1936290409, // 'siri': Siri/system audio session conflict
            -50, // kAudio_ParamError: invalid parameter (session not active)
        ]
#if os(iOS) || os(visionOS)
        deferredCodes.insert(Int(AVAudioSession.ErrorCode.cannotStartPlaying.rawValue))
#endif
        return deferredCodes.contains(nsError.code)
    }
}

#if os(iOS) || os(visionOS)
private struct MirageSystemAudioSessionDriver: MirageClientAudioSessionDriving {
    var isApplicationActive: Bool {
        UIApplication.shared.applicationState == .active
    }

    func activate(_ configuration: MirageClientAudioSessionConfiguration) throws {
        let session = AVAudioSession.sharedInstance()
        switch configuration {
        case .playback:
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
        case .dictation:
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.mixWithOthers, .defaultToSpeaker])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        }
    }

    func deactivate() throws {
        try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
#else
private struct MirageSystemAudioSessionDriver: MirageClientAudioSessionDriving {
    var isApplicationActive: Bool { true }

    func activate(_ configuration: MirageClientAudioSessionConfiguration) throws {
        _ = configuration
    }

    func deactivate() throws {}
}
#endif
