//
//  InputCapturingView+Dictation.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/10/26.
//
//  Live dictation handling for iOS and visionOS client input.
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
#if os(iOS) || os(visionOS)
import AVFAudio
import Speech
import UIKit

extension InputCapturingView {
    func handleDictationToggleRequest(_ requestID: UInt64) {
        guard requestID > lastHandledDictationToggleRequestID else { return }
        lastHandledDictationToggleRequestID = requestID

        if isDictationActive {
            stopDictation()
        } else {
            startDictation()
        }
    }

    func startDictation() {
        guard !isDictationActive else { return }
        MirageLogger.client("Dictation start requested mode=\(dictationMode.rawValue)")
        dictationResultBuffer.reset()
        let inputLevelHandler = beginDictationInputLevelSession()

        dictationFinalizeTask?.cancel()
        dictationFinalizeTask = nil
        dictationResultTask?.cancel()
        dictationResultTask = nil
        dictationTask?.cancel()
        dictationTask = Task { @MainActor [weak self] in
            guard let self else { return }

            do {
                try await requestDictationPermissions()
                try await configureAudioSessionForDictation()
                let dictationLocale = try await resolveDictationLocale()
                MirageLogger.client("Dictation permissions and audio session ready")
                MirageLogger.client("Starting modern dictation analyzer locale=\(dictationLocale.identifier)")
                try await startSpeechAnalyzerDictationModern(
                    locale: dictationLocale,
                    inputLevelHandler: inputLevelHandler
                )

                isDictationActive = true
                onDictationStateChanged?(true)
            } catch {
                MirageLogger.client("Dictation start failed: \(error.localizedDescription)")
                stopDictation()
                onDictationError?(dictationErrorMessage(for: error))
            }
        }
    }

    func stopDictation() {
        let activeDictationTask = dictationTask
        dictationTask = nil

        dictationFinalizeTask?.cancel()
        dictationFinalizeTask = nil

        let analyzerObject = dictationAnalyzer
        let analyzerInputSinkObject = dictationAnalyzerInputSink
        let reservedLocale = dictationReservedLocale
        let hasAnalyzer = analyzerObject is SpeechAnalyzer

        (analyzerInputSinkObject as? AnalyzerInputSink)?.finish()
        dictationAnalyzerInputSink = nil
        dictationAnalyzer = nil
        dictationReservedLocale = nil

        if dictationMode == .best, hasAnalyzer {
            // Keep listening for final result until analyzer flush completes.
            dictationFinalizeTask = Task { @MainActor [weak self] in
                defer { self?.dictationFinalizeTask = nil }
                if let analyzer = analyzerObject as? SpeechAnalyzer {
                    do {
                        try await analyzer.finalizeAndFinishThroughEndOfInput()
                    } catch {
                        MirageLogger.error(.client, error: error, message: "Failed to finalize dictation analyzer: ")
                    }
                }
                if let resultTask = self?.dictationResultTask {
                    await resultTask.value
                }
                self?.flushBufferedDictationFinalSegments()
                self?.dictationResultTask = nil
                activeDictationTask?.cancel()
                if let reservedLocale {
                    _ = await AssetInventory.release(reservedLocale: reservedLocale)
                }
            }
        } else {
            activeDictationTask?.cancel()
            dictationResultTask?.cancel()
            dictationResultTask = nil
            if let analyzer = analyzerObject as? SpeechAnalyzer {
                Task {
                    do {
                        try await analyzer.finalizeAndFinishThroughEndOfInput()
                    } catch {
                        MirageLogger.error(.client, error: error, message: "Failed to finalize cancelled dictation analyzer: ")
                    }
                }
            }
            if let reservedLocale {
                Task { _ = await AssetInventory.release(reservedLocale: reservedLocale) }
            }
        }

        if let engine = dictationAudioEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        dictationAudioEngine = nil
        endDictationInputLevelSession()

        if !(dictationMode == .best && hasAnalyzer) {
            dictationResultBuffer.reset()
        }

        if isDictationActive {
            isDictationActive = false
            onDictationStateChanged?(false)
        }

        Task {
            await MirageClientAudioSessionCoordinator.shared.releaseDictationSession()
        }
    }

    private func requestDictationPermissions() async throws {
        let microphoneGranted = await AVAudioApplication.requestRecordPermission()
        guard microphoneGranted else {
            MirageLogger.client("Dictation microphone permission denied")
            throw DictationError.microphonePermissionDenied
        }

        let speechAuthorization = await SpeechAuthorizationBridge.requestStatus()
        guard speechAuthorization == .authorized else {
            MirageLogger.client("Dictation speech authorization denied status=\(speechAuthorization.rawValue)")
            throw DictationError.speechPermissionDenied
        }
    }

    private func configureAudioSessionForDictation() async throws {
        guard await MirageClientAudioSessionCoordinator.shared.requestDictationSession() else {
            throw DictationError.audioSessionUnavailable
        }
    }

    private func resolveDictationLocale() async throws -> Locale {
        guard let locale = await MirageDictationLocaleSupport.resolvedLocale(for: dictationLocalePreference) else {
            MirageLogger.client("Dictation locale resolution failed preference=\(dictationLocalePreference.rawValue)")
            throw DictationError.dictationUnavailable
        }
        return locale
    }

    private func beginDictationInputLevelSession() -> ((AVAudioPCMBuffer) -> Void)? {
        dictationInputLevelGeneration &+= 1
        dictationInputLevelMeter.reset()

        guard onDictationInputLevelChanged != nil else { return nil }
        let generation = dictationInputLevelGeneration
        let meter = dictationInputLevelMeter

        return { [weak self, meter] buffer in
            guard let level = meter.process(buffer) else { return }
            Task { @MainActor [weak self] in
                guard let self, dictationInputLevelGeneration == generation else { return }
                onDictationInputLevelChanged?(level)
            }
        }
    }

    private func endDictationInputLevelSession() {
        dictationInputLevelGeneration &+= 1
        dictationInputLevelMeter.reset()
        onDictationInputLevelChanged?(0)
    }

    func handleDictationResultText(_ fullText: String) {
        guard let delta = dictationResultBuffer.delta(forCumulativeText: fullText) else { return }
        sendDictationText(delta)
    }

    func flushBufferedDictationFinalSegments() {
        let orderedSegments = dictationResultBuffer.drainFinalSegments()
        for segment in orderedSegments {
            sendDictationText(segment)
        }
    }

    func sendDictationText(_ text: String) {
        let modifiers: MirageInput.MirageModifierFlags = []
        for scalar in text {
            let character = String(scalar)
            if character == "\n" {
                sendSoftwareKeyEvent(
                    keyCode: 0x24,
                    characters: "\n",
                    charactersIgnoringModifiers: "\n",
                    modifiers: modifiers
                )
                continue
            }

            guard let event = MirageClientKeyEventBuilder.softwareKeyEvent(
                for: character,
                baseModifiers: modifiers
            ) else { continue }
            sendSoftwareKeyEvent(
                keyCode: event.keyCode,
                characters: event.characters,
                charactersIgnoringModifiers: event.charactersIgnoringModifiers,
                modifiers: event.modifiers
            )
        }
    }

    func dictationErrorMessage(for error: Error) -> String {
        if let dictationError = error as? DictationError {
            switch dictationError {
            case .microphonePermissionDenied:
                return "Microphone permission is required for dictation."
            case .speechPermissionDenied:
                return "Speech recognition permission is required for dictation."
            case .dictationUnavailable:
                return "Dictation is unavailable for the current locale."
            case .streamInitializationFailed:
                return "Dictation input stream could not be created."
            case .audioSessionUnavailable:
                return "Dictation audio session could not be activated."
            }
        }

        let nsError = error as NSError
        if !nsError.localizedDescription.isEmpty {
            return "Dictation failed: \(nsError.localizedDescription)"
        }
        return "Dictation failed."
    }
}

#endif
