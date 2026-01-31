//
//  AudioCaptureEngine.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/30/26.
//
//  ScreenCaptureKit audio capture.
//

import Foundation
import CoreMedia

#if os(macOS)
import ScreenCaptureKit

@MainActor
final class AudioCaptureEngine: NSObject {
    enum Target {
        case system(display: SCDisplay)
        case app(window: SCWindow, display: SCDisplay)
    }

    private var stream: SCStream?
    private var output: AudioStreamOutput?

    func startCapture(
        target: Target,
        onSampleBuffer: @escaping @Sendable (CMSampleBuffer) -> Void
    ) async throws {
        guard stream == nil else {
            throw MirageError.protocolError("Audio capture already running")
        }

        let streamConfig = SCStreamConfiguration()
        streamConfig.capturesAudio = true
        streamConfig.excludesCurrentProcessAudio = true

        let filter: SCContentFilter
        switch target {
        case .system(let display):
            filter = SCContentFilter(display: display, excludingWindows: [])
        case .app(let window, _):
            filter = SCContentFilter(desktopIndependentWindow: window)
        }

        let stream = SCStream(filter: filter, configuration: streamConfig, delegate: nil)
        let output = AudioStreamOutput(onSampleBuffer: onSampleBuffer)
        let audioQueue = DispatchQueue(label: "com.mirage.capture.audio", qos: .userInitiated)
        try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: audioQueue)
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: audioQueue)

        try await stream.startCapture()
        self.stream = stream
        self.output = output
    }

    func stopCapture() async {
        guard let stream else { return }
        do {
            try await stream.stopCapture()
        } catch {
            MirageLogger.error(.capture, "Error stopping audio capture: \(error)")
        }
        self.stream = nil
        self.output = nil
    }
}

final class AudioStreamOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    private let onSampleBuffer: @Sendable (CMSampleBuffer) -> Void

    init(onSampleBuffer: @escaping @Sendable (CMSampleBuffer) -> Void) {
        self.onSampleBuffer = onSampleBuffer
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        onSampleBuffer(sampleBuffer)
    }
}

struct AudioSampleBuffer: @unchecked Sendable {
    let buffer: CMSampleBuffer
}
#endif
