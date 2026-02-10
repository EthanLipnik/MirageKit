//
//  InputCapturingView+Dictation.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/10/26.
//
//  Live dictation handling for iOS and visionOS client input.
//

import MirageKit
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

                if #available(iOS 26.0, visionOS 26.0, *) {
                    try await startSpeechAnalyzerDictationModern()
                } else {
                    try startSpeechRecognizerDictationLegacy()
                }

                isDictationActive = true
                onDictationStateChanged?(true)
            } catch {
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
        let recognitionTask = dictationRecognitionTask
        let recognitionRequest = dictationRecognitionRequest
        var hasModernAnalyzer = false

        if #available(iOS 26.0, visionOS 26.0, *) {
            (analyzerInputSinkObject as? AnalyzerInputSink)?.finish()
            hasModernAnalyzer = analyzerObject is SpeechAnalyzer
        }
        dictationAnalyzerInputSink = nil
        dictationAnalyzer = nil
        dictationReservedLocale = nil

        if dictationMode == .best, hasModernAnalyzer {
            // Keep listening for final result until analyzer flush completes.
            dictationFinalizeTask = Task { @MainActor [weak self] in
                defer { self?.dictationFinalizeTask = nil }
                if #available(iOS 26.0, visionOS 26.0, *),
                   let analyzer = analyzerObject as? SpeechAnalyzer {
                    try? await analyzer.finalizeAndFinishThroughEndOfInput()
                }
                self?.dictationResultTask?.cancel()
                self?.dictationResultTask = nil
                activeDictationTask?.cancel()
                if #available(iOS 26.0, visionOS 26.0, *), let reservedLocale {
                    _ = await AssetInventory.release(reservedLocale: reservedLocale)
                }
            }
        } else {
            activeDictationTask?.cancel()
            dictationResultTask?.cancel()
            dictationResultTask = nil
            if #available(iOS 26.0, visionOS 26.0, *),
               let analyzer = analyzerObject as? SpeechAnalyzer {
                Task { try? await analyzer.finalizeAndFinishThroughEndOfInput() }
            }
            if #available(iOS 26.0, visionOS 26.0, *), let reservedLocale {
                Task { _ = await AssetInventory.release(reservedLocale: reservedLocale) }
            }
        }

        dictationRecognitionTask = nil
        dictationRecognitionRequest = nil

        if dictationMode == .best, !hasModernAnalyzer, let recognitionTask {
            recognitionRequest?.endAudio()
            dictationFinalizeTask = Task { @MainActor [weak self] in
                defer { self?.dictationFinalizeTask = nil }
                try? await Task.sleep(for: .milliseconds(350))
                recognitionTask.cancel()
            }
        } else {
            recognitionTask?.cancel()
            recognitionRequest?.endAudio()
        }

        if let engine = dictationAudioEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        dictationAudioEngine = nil

        dictationLastCommittedText = ""

        if isDictationActive {
            isDictationActive = false
            onDictationStateChanged?(false)
        }

        Task { @MainActor in
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    private func requestDictationPermissions() async throws {
        let microphoneGranted = await AVAudioApplication.requestRecordPermission()
        guard microphoneGranted else { throw DictationError.microphonePermissionDenied }

        let speechAuthorization = await SpeechAuthorizationBridge.requestStatus()
        guard speechAuthorization == .authorized else { throw DictationError.speechPermissionDenied }
    }

    private func configureAudioSessionForDictation() async throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.mixWithOthers, .defaultToSpeaker])
        try session.setActive(true, options: .notifyOthersOnDeactivation)
    }

    @available(iOS 26.0, visionOS 26.0, *)
    private func startSpeechAnalyzerDictationModern() async throws {
        let locale = Locale.autoupdatingCurrent
        let moduleChoice = DictationModuleChoice(locale: locale, mode: dictationMode)
        dictationLastCommittedText = ""
        if let selectedLocale = moduleChoice.selectedLocale {
            do {
                let reserved = try await AssetInventory.reserve(locale: selectedLocale)
                if reserved { dictationReservedLocale = selectedLocale }
            } catch {
                MirageLogger.client("Dictation locale reservation failed: \(error.localizedDescription)")
            }
        }

        var streamContinuation: AsyncStream<AnalyzerInput>.Continuation?
        let stream = AsyncStream<AnalyzerInput> { continuation in
            streamContinuation = continuation
        }
        guard let streamContinuation else { throw DictationError.streamInitializationFailed }

        let analyzer = SpeechAnalyzer(modules: [moduleChoice.module])
        dictationAnalyzer = analyzer

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        let preferredAnalyzerFormatCandidate = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [moduleChoice.module],
            considering: inputFormat
        )
        let secondaryAnalyzerFormatCandidate = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [moduleChoice.module]
        )
        let preferredAnalyzerFormat = preferredAnalyzerFormatCandidate ?? secondaryAnalyzerFormatCandidate
        guard let analyzerInputFormat = speechAnalyzerInputFormat(
            forAnalyzerPreferredFormat: preferredAnalyzerFormat,
            fallback: inputFormat
        ) else {
            throw DictationError.streamInitializationFailed
        }
        let analyzerSink = AnalyzerInputSink(continuation: streamContinuation)
        let analyzerConverter = DictationAnalyzerConverter(
            sourceFormat: inputFormat,
            targetFormat: analyzerInputFormat
        )
        dictationAnalyzerInputSink = analyzerSink
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(
            onBus: 0,
            bufferSize: 1024,
            format: nil,
            block: makeAnalyzerInputTapBlock(sink: analyzerSink, converter: analyzerConverter)
        )

        try engine.start()
        dictationAudioEngine = engine

        dictationResultTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                switch moduleChoice {
                case let .speechTranscriber(transcriber):
                    for try await result in transcriber.results {
                        if dictationMode == .best, !result.isFinal { continue }
                        handleDictationResultText(String(result.text.characters))
                    }
                case let .dictationTranscriber(transcriber):
                    for try await result in transcriber.results {
                        if dictationMode == .best, !result.isFinal { continue }
                        handleDictationResultText(String(result.text.characters))
                    }
                }
            } catch {
                if !Task.isCancelled {
                    stopDictation()
                    onDictationError?(dictationErrorMessage(for: error))
                }
            }
        }

        dictationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await analyzer.start(inputSequence: stream)
            } catch {
                if !Task.isCancelled {
                    stopDictation()
                    onDictationError?(dictationErrorMessage(for: error))
                }
            }
        }
    }

    private func startSpeechRecognizerDictationLegacy() throws {
        dictationLastCommittedText = ""

        guard let recognizer = SFSpeechRecognizer(locale: .autoupdatingCurrent), recognizer.isAvailable else {
            throw DictationError.recognizerUnavailable
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = dictationMode == .realTime
        dictationRecognitionRequest = request

        dictationRecognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self else { return }

                if let result {
                    if dictationMode == .best {
                        if result.isFinal {
                            handleDictationResultText(result.bestTranscription.formattedString)
                        }
                    } else {
                        handleDictationResultText(result.bestTranscription.formattedString)
                    }
                }

                if let error {
                    stopDictation()
                    onDictationError?(dictationErrorMessage(for: error))
                }
            }
        }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        let recognitionRequest = request
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(
            onBus: 0,
            bufferSize: 1024,
            format: inputFormat,
            block: makeLegacyRecognitionTapBlock(request: recognitionRequest)
        )

        try engine.start()
        dictationAudioEngine = engine
    }

    private func handleDictationResultText(_ fullText: String) {
        guard !fullText.isEmpty else { return }

        if fullText.hasPrefix(dictationLastCommittedText) {
            let delta = String(fullText.dropFirst(dictationLastCommittedText.count))
            if !delta.isEmpty {
                sendDictationText(delta)
                dictationLastCommittedText = fullText
            }
            return
        }

        sendDictationText(fullText)
        dictationLastCommittedText = fullText
    }

    private func sendDictationText(_ text: String) {
        let modifiers: MirageModifierFlags = []
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

            guard let event = softwareKeyEvent(for: character, baseModifiers: modifiers) else { continue }
            sendSoftwareKeyEvent(
                keyCode: event.keyCode,
                characters: event.characters,
                charactersIgnoringModifiers: event.charactersIgnoringModifiers,
                modifiers: event.modifiers
            )
        }
    }

    private func dictationErrorMessage(for error: Error) -> String {
        if let dictationError = error as? DictationError {
            switch dictationError {
            case .microphonePermissionDenied:
                return "Microphone permission is required for dictation."
            case .speechPermissionDenied:
                return "Speech recognition permission is required for dictation."
            case .recognizerUnavailable:
                return "Speech recognizer is unavailable for the current locale."
            case .streamInitializationFailed:
                return "Dictation input stream could not be created."
            }
        }

        let nsError = error as NSError
        if !nsError.localizedDescription.isEmpty {
            return "Dictation failed: \(nsError.localizedDescription)"
        }
        return "Dictation failed."
    }

}

@available(iOS 26.0, visionOS 26.0, *)
private enum DictationModuleChoice {
    case speechTranscriber(SpeechTranscriber)
    case dictationTranscriber(DictationTranscriber)

    init(locale: Locale, mode: MirageDictationMode) {
        if SpeechTranscriber.isAvailable {
            switch mode {
            case .realTime:
                self = .speechTranscriber(SpeechTranscriber(locale: locale, preset: .progressiveTranscription))
            case .best:
                self = .speechTranscriber(SpeechTranscriber(locale: locale, preset: .transcription))
            }
        } else {
            switch mode {
            case .realTime:
                self = .dictationTranscriber(DictationTranscriber(locale: locale, preset: .progressiveLongDictation))
            case .best:
                self = .dictationTranscriber(DictationTranscriber(locale: locale, preset: .longDictation))
            }
        }
    }

    var module: any SpeechModule {
        switch self {
        case let .speechTranscriber(module):
            return module
        case let .dictationTranscriber(module):
            return module
        }
    }

    var selectedLocale: Locale? {
        switch self {
        case let .speechTranscriber(module):
            return module.selectedLocales.first
        case let .dictationTranscriber(module):
            return module.selectedLocales.first
        }
    }
}

private enum DictationError: Error {
    case microphonePermissionDenied
    case speechPermissionDenied
    case recognizerUnavailable
    case streamInitializationFailed
}

private enum SpeechAuthorizationBridge {
    static func requestStatus() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }
}

@available(iOS 26.0, visionOS 26.0, *)
private final class AnalyzerInputSink: @unchecked Sendable {
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private let queue = DispatchQueue(label: "com.ethanlipnik.mirage.dictation.analyzer-input", qos: .userInitiated)
    private var finished = false

    init(continuation: AsyncStream<AnalyzerInput>.Continuation) {
        self.continuation = continuation
    }

    func yield(_ buffer: AVAudioPCMBuffer) {
        queue.async { [weak self] in
            guard let self, !self.finished else { return }
            guard buffer.format.commonFormat == .pcmFormatInt16 else { return }
            self.continuation.yield(AnalyzerInput(buffer: buffer))
        }
    }

    func finish() {
        queue.async { [weak self] in
            guard let self, !self.finished else { return }
            self.finished = true
            self.continuation.finish()
        }
    }
}

@available(iOS 26.0, visionOS 26.0, *)
private final class DictationAnalyzerConverter: @unchecked Sendable {
    let sourceFormat: AVAudioFormat
    let targetFormat: AVAudioFormat
    private let converter: AVAudioConverter?

    init(sourceFormat: AVAudioFormat, targetFormat: AVAudioFormat) {
        self.sourceFormat = sourceFormat
        self.targetFormat = targetFormat
        if sourceFormat == targetFormat {
            converter = nil
        } else {
            converter = AVAudioConverter(from: sourceFormat, to: targetFormat)
        }
    }

    func convert(_ sourceBuffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let converter else {
            guard sourceBuffer.format.commonFormat == .pcmFormatInt16 else { return nil }
            return copyPCMBufferForDictation(sourceBuffer)
        }

        let outputFrameCapacity = AVAudioFrameCount(
            (Double(sourceBuffer.frameLength) * targetFormat.sampleRate / sourceFormat.sampleRate).rounded(.up)
        )
        guard outputFrameCapacity > 0 else { return nil }
        guard let convertedBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: outputFrameCapacity + 1
        ) else {
            return nil
        }

        var consumedSource = false
        var conversionError: NSError?
        let status = converter.convert(to: convertedBuffer, error: &conversionError) { _, outStatus in
            if consumedSource {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumedSource = true
            outStatus.pointee = .haveData
            return sourceBuffer
        }

        if let conversionError {
            MirageLogger.client("Dictation converter error: \(conversionError.localizedDescription)")
            return nil
        }

        switch status {
        case .haveData, .inputRanDry, .endOfStream:
            if convertedBuffer.frameLength > 0, convertedBuffer.format.commonFormat == .pcmFormatInt16 {
                return convertedBuffer
            }
            return nil
        case .error:
            return nil
        @unknown default:
            return nil
        }
    }
}

@available(iOS 26.0, visionOS 26.0, *)
private func makeAnalyzerInputTapBlock(
    sink: AnalyzerInputSink,
    converter: DictationAnalyzerConverter
) -> AVAudioNodeTapBlock {
    { buffer, _ in
        guard let copiedBuffer = copyPCMBufferForDictation(buffer) else { return }
        guard let convertedBuffer = converter.convert(copiedBuffer) else { return }
        sink.yield(convertedBuffer)
    }
}

private func makeLegacyRecognitionTapBlock(
    request: SFSpeechAudioBufferRecognitionRequest
) -> AVAudioNodeTapBlock {
    { buffer, _ in
        request.append(buffer)
    }
}

private func speechAnalyzerInputFormat(
    forAnalyzerPreferredFormat preferredFormat: AVAudioFormat?,
    fallback fallbackFormat: AVAudioFormat
) -> AVAudioFormat? {
    if let preferredFormat {
        if preferredFormat.commonFormat == .pcmFormatInt16 { return preferredFormat }

        if let int16Preferred = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: preferredFormat.sampleRate,
            channels: max(preferredFormat.channelCount, 1),
            interleaved: preferredFormat.isInterleaved
        ) {
            return int16Preferred
        }
    }

    if let int16SpeechDefault = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    ) {
        return int16SpeechDefault
    }

    if let int16Fallback = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: fallbackFormat.sampleRate,
        channels: max(fallbackFormat.channelCount, 1),
        interleaved: false
    ) {
        return int16Fallback
    }

    return nil
}

private func copyPCMBufferForDictation(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
    guard let copy = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: source.frameCapacity) else {
        return nil
    }
    copy.frameLength = source.frameLength

    let sourceBufferList = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
    let destinationBufferList = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
    guard sourceBufferList.count == destinationBufferList.count else { return copy }

    for index in 0 ..< sourceBufferList.count {
        let sourceBuffer = sourceBufferList[index]
        let destinationBuffer = destinationBufferList[index]
        guard let sourceData = sourceBuffer.mData, let destinationData = destinationBuffer.mData else {
            continue
        }
        memcpy(destinationData, sourceData, Int(sourceBuffer.mDataByteSize))
    }

    return copy
}
#endif
