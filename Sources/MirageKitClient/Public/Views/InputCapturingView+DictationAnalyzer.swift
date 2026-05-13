//
//  InputCapturingView+DictationAnalyzer.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/13/26.
//

import MirageKit

#if os(iOS) || os(visionOS)
import AVFAudio
import Speech

extension InputCapturingView {
    /// Starts dictation through the modern SpeechAnalyzer pipeline.
    @available(iOS 26.0, visionOS 26.0, *)
    func startSpeechAnalyzerDictationModern(
        locale: Locale,
        inputLevelHandler: ((AVAudioPCMBuffer) -> Void)?
    ) async throws {
        let moduleChoice = DictationModuleChoice(locale: locale, mode: dictationMode)
        MirageLogger.client("Dictation analyzer module=\(String(describing: moduleChoice)) locale=\(locale.identifier)")
        dictationResultBuffer.reset()
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
            block: makeAnalyzerInputTapBlock(
                sink: analyzerSink,
                converter: analyzerConverter,
                inputLevelHandler: inputLevelHandler
            )
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
                        if dictationMode == .best {
                            dictationResultBuffer.bufferFinalSegment(
                                text: String(result.text.characters),
                                range: result.range
                            )
                        } else {
                            handleDictationResultText(String(result.text.characters))
                        }
                    }
                case let .dictationTranscriber(transcriber):
                    for try await result in transcriber.results {
                        if dictationMode == .best, !result.isFinal { continue }
                        if dictationMode == .best {
                            dictationResultBuffer.bufferFinalSegment(
                                text: String(result.text.characters),
                                range: result.range
                            )
                        } else {
                            handleDictationResultText(String(result.text.characters))
                        }
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
}
#endif
