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

/// Audio session mode requested by Mirage client features.
enum MirageClientAudioSessionConfiguration: Equatable {
    /// Output-only mode used by host audio playback.
    case playback
    /// Input-capable mode used while dictation owns the shared session.
    case dictation
}

/// Platform audio-session adapter used by the coordinator and tests.
protocol MirageClientAudioSessionDriving: Sendable {
    /// Returns whether the application can safely activate an audio session now.
    var isApplicationActive: Bool { get async }
    /// Activates the platform audio session for host audio playback.
    func activatePlaybackSession() async throws
    /// Activates the platform audio session for dictation capture.
    func activateDictationSession() async throws
    /// Deactivates the platform audio session after all leases are released.
    func deactivate() async throws
}

/// Arbitrates the shared client audio session between playback and dictation.
actor MirageClientAudioSessionCoordinator {
    static let shared = MirageClientAudioSessionCoordinator()

    private let driver: any MirageClientAudioSessionDriving
    private var playbackLeaseCount = 0
    private var dictationLeaseCount = 0
    private var currentConfiguration: MirageClientAudioSessionConfiguration?
    private var pendingActivationConfiguration: MirageClientAudioSessionConfiguration?
    private var activationFailureCount = 0
    private var activationBackoffUntil: ContinuousClock.Instant?
    private var loggedInactiveDeferral = false

    private static let maxActivationRetries = 3
    private static let activationWaitTimeout: Duration = .milliseconds(750)
    private static let activationWaitPollInterval: Duration = .milliseconds(50)
    private static let activationBackoffs: [Duration] = [
        .milliseconds(100),
        .milliseconds(500),
        .seconds(2),
    ]
    /// Audio-session error codes that usually mean activation should be retried after app/session recovery.
    private static let deferredActivationErrorCodes: Set<Int> = {
        var codes: Set<Int> = [
            1_836_282_486, // 'msrv': media services failed
            561_210_739, // '!ses': session unavailable while mediaserverd is recovering
            561_017_449, // '!ini': session not initialized
            1_936_290_409, // 'siri': Siri/system audio session conflict
            -50, // kAudio_ParamError: invalid parameter (session not active)
        ]
        #if os(iOS) || os(visionOS)
        codes.insert(Int(AVAudioSession.ErrorCode.cannotStartPlaying.rawValue))
        #endif
        return codes
    }()

    init(driver: any MirageClientAudioSessionDriving = MirageSystemAudioSessionDriver()) {
        self.driver = driver
    }

    /// Requests a playback lease and activates the session if no higher-priority mode is active.
    func requestPlaybackSession() async -> Bool {
        playbackLeaseCount += 1
        await refreshSessionIfNeeded()
        let isActive = currentConfiguration != nil
        if !isActive {
            playbackLeaseCount -= 1
        }
        return isActive
    }

    /// Releases one playback lease and deactivates the session when no audio feature still needs it.
    func releasePlaybackSession() async {
        guard playbackLeaseCount > 0 else { return }
        playbackLeaseCount -= 1
        await refreshSessionIfNeeded()
    }

    /// Reapplies the currently desired platform session without changing lease ownership.
    func reassertActiveSession() async -> Bool {
        guard desiredConfiguration != nil else { return false }
        currentConfiguration = nil
        pendingActivationConfiguration = nil
        activationBackoffUntil = nil
        await refreshSessionIfNeeded()
        return currentConfiguration != nil
    }

    /// Requests a dictation lease, preempting playback because dictation needs an input-capable session.
    func requestDictationSession() async -> Bool {
        dictationLeaseCount += 1
        await refreshSessionIfNeeded()
        let isActive = currentConfiguration == .dictation
        if !isActive {
            dictationLeaseCount -= 1
        }
        return isActive
    }

    /// Releases one dictation lease and restores playback mode when playback leases remain.
    func releaseDictationSession() async {
        guard dictationLeaseCount > 0 else { return }
        dictationLeaseCount -= 1
        await refreshSessionIfNeeded()
    }

    #if os(iOS) || os(visionOS)
    /// Retries deferred activation after UIKit reports that the app became active.
    func handleApplicationDidBecomeActive() async {
        loggedInactiveDeferral = false
        await refreshSessionIfNeeded()
    }
    #endif

    /// Preferred session mode for the current leases; dictation wins over playback.
    private var desiredConfiguration: MirageClientAudioSessionConfiguration? {
        if dictationLeaseCount > 0 {
            return .dictation
        }
        if playbackLeaseCount > 0 {
            return .playback
        }
        return nil
    }

    /// Converges the platform audio session toward the currently desired lease state.
    private func refreshSessionIfNeeded() async {
        guard let desiredConfiguration else {
            await deactivateIfNeeded()
            return
        }

        if await !(driver.isApplicationActive) {
            if !loggedInactiveDeferral {
                MirageLogger.client("Deferring shared audio session activation until app becomes active")
                loggedInactiveDeferral = true
            }
            guard await waitForApplicationActivation() else {
                return
            }
        }

        loggedInactiveDeferral = false

        if currentConfiguration == desiredConfiguration {
            return
        }
        if pendingActivationConfiguration == desiredConfiguration {
            return
        }

        if let activationBackoffUntil, ContinuousClock.now < activationBackoffUntil {
            return
        }

        pendingActivationConfiguration = desiredConfiguration
        do {
            switch desiredConfiguration {
            case .playback:
                try await driver.activatePlaybackSession()
            case .dictation:
                try await driver.activateDictationSession()
            }
            currentConfiguration = desiredConfiguration
            pendingActivationConfiguration = nil
            activationFailureCount = 0
            activationBackoffUntil = nil
        } catch {
            if pendingActivationConfiguration == desiredConfiguration {
                pendingActivationConfiguration = nil
            }
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
                return
            }

            MirageLogger.error(.client, error: error, message: "Shared audio session setup failed: ")
        }
    }

    /// Deactivates the platform session and resets retry state when no leases remain.
    private func deactivateIfNeeded() async {
        guard currentConfiguration != nil else { return }
        currentConfiguration = nil
        pendingActivationConfiguration = nil
        activationFailureCount = 0
        activationBackoffUntil = nil
        loggedInactiveDeferral = false
        do {
            try await driver.deactivate()
        } catch {
            MirageLogger.error(.client, error: error, message: "Shared audio session deactivation failed: ")
        }
    }

    /// Waits briefly for foreground activation before treating the request as deferred.
    private func waitForApplicationActivation() async -> Bool {
        let deadline = ContinuousClock.now + Self.activationWaitTimeout
        while ContinuousClock.now < deadline {
            do {
                try await Task.sleep(for: Self.activationWaitPollInterval)
            } catch {
                return false
            }
            if await driver.isApplicationActive {
                return true
            }
        }
        return await driver.isApplicationActive
    }

    /// Returns whether an activation failure is transient enough to retry instead of surfacing immediately.
    private func shouldSuppressActivationError(_ error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == NSOSStatusErrorDomain
            || nsError.domain == "com.apple.coreaudio.avfaudio" else {
            return false
        }

        return Self.deferredActivationErrorCodes.contains(nsError.code)
    }
}

#if os(iOS) || os(visionOS)
private struct MirageSystemAudioSessionDriver: MirageClientAudioSessionDriving {
    var isApplicationActive: Bool {
        get async {
            await MainActor.run {
                UIApplication.shared.applicationState == .active
            }
        }
    }

    func activatePlaybackSession() async throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try session.setActive(true)
    }

    func activateDictationSession() async throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.mixWithOthers, .defaultToSpeaker])
        try session.setActive(true, options: .notifyOthersOnDeactivation)
    }

    func deactivate() async throws {
        try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
#else
private struct MirageSystemAudioSessionDriver: MirageClientAudioSessionDriving {
    /// Non-iOS platforms do not need foreground gating for this shared audio-session adapter.
    var isApplicationActive: Bool { true }

    /// Non-iOS platforms do not use `AVAudioSession`; audio activation is handled by their playback stack.
    func activatePlaybackSession() async throws {}

    /// Non-iOS platforms do not use `AVAudioSession`; audio activation is handled by their dictation stack.
    func activateDictationSession() async throws {}

    /// Non-iOS platforms do not use `AVAudioSession`; audio deactivation is handled by their playback stack.
    func deactivate() async throws {}
}
#endif
