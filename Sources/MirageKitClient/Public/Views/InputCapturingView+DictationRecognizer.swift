//
//  InputCapturingView+DictationRecognizer.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/13/26.
//

import MirageKit

#if os(iOS) || os(visionOS)
import AVFAudio
import Speech

extension InputCapturingView {
    /// Starts dictation through the SFSpeechRecognizer fallback pipeline.
    func startSpeechRecognizerDictation(
        locale: Locale,
        inputLevelHandler: ((AVAudioPCMBuffer) -> Void)?
    ) throws {
        dictationResultBuffer.reset()

        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            MirageLogger.client("Speech recognition dictation unavailable locale=\(locale.identifier)")
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
            block: makeSpeechRecognitionTapBlock(
                request: recognitionRequest,
                inputLevelHandler: inputLevelHandler
            )
        )

        try engine.start()
        dictationAudioEngine = engine
    }
}
#endif
