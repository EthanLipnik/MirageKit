//
//  InputCapturingView+DictationSupport.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/12/26.
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

/// Chooses the modern speech module that best matches the requested dictation mode.
enum DictationModuleChoice {
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

    /// Speech module passed to `SpeechAnalyzer`.
    var module: any SpeechModule {
        switch self {
        case let .speechTranscriber(module):
            module
        case let .dictationTranscriber(module):
            module
        }
    }

    /// Locale selected by the speech module after availability resolution.
    var selectedLocale: Locale? {
        switch self {
        case let .speechTranscriber(module):
            module.selectedLocales.first
        case let .dictationTranscriber(module):
            module.selectedLocales.first
        }
    }
}

/// User-actionable failures that can occur while starting dictation.
enum DictationError: Error {
    case microphonePermissionDenied
    case speechPermissionDenied
    case dictationUnavailable
    case streamInitializationFailed
    case audioSessionUnavailable
}

/// Async wrapper around Speech's callback-based authorization API.
enum SpeechAuthorizationBridge {
    static func requestStatus() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }
}

/// Thread-safe sink that feeds converted audio buffers into a speech analyzer stream.
final class AnalyzerInputSink: @unchecked Sendable {
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private let queue = DispatchQueue(label: "io.miragekit.client.dictation.analyzer-input", qos: .userInitiated)
    private var finished = false

    init(continuation: AsyncStream<AnalyzerInput>.Continuation) {
        self.continuation = continuation
    }

    func yield(_ buffer: AVAudioPCMBuffer) {
        queue.async { [weak self] in
            guard let self, !self.finished else { return }
            guard buffer.format.commonFormat == .pcmFormatInt16 else { return }
            continuation.yield(AnalyzerInput(buffer: buffer))
        }
    }

    func finish() {
        queue.async { [weak self] in
            guard let self, !self.finished else { return }
            finished = true
            continuation.finish()
        }
    }
}

/// Converts microphone buffers into the PCM format required by the modern speech analyzer.
final class DictationAnalyzerConverter: @unchecked Sendable {
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

/// Builds an audio tap that copies, converts, and forwards analyzer input.
func makeAnalyzerInputTapBlock(
    sink: AnalyzerInputSink,
    converter: DictationAnalyzerConverter,
    inputLevelHandler: ((AVAudioPCMBuffer) -> Void)?
) -> AVAudioNodeTapBlock {
    { buffer, _ in
        inputLevelHandler?(buffer)
        guard let copiedBuffer = copyPCMBufferForDictation(buffer) else { return }
        guard let convertedBuffer = converter.convert(copiedBuffer) else { return }
        sink.yield(convertedBuffer)
    }
}

/// Resolves the analyzer input format, preferring 16-bit PCM because `AnalyzerInput` requires it.
func speechAnalyzerInputFormat(
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
        sampleRate: 16000,
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

/// Copies an audio buffer before crossing queues or handing it to a converter.
func copyPCMBufferForDictation(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
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
