//
//  StreamContextAudioCaptureChannelTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/3/26.
//
//  Coverage for stream-level audio capture channel plumbing.
//

@testable import MirageKitHost
import MirageKit
import Testing

#if os(macOS)
@Suite("Stream Context Audio Capture Channel")
struct StreamContextAudioCaptureChannelTests {
    @Test("Defaults to stereo capture channels")
    func defaultChannelCount() async {
        let context = makeContext()
        #expect(await context.getRequestedAudioChannelCount() == MirageAudioChannelLayout.stereo.channelCount)
    }

    @Test("Initializer respects requested channel count")
    func initializerUsesRequestedChannelCount() async {
        let context = makeContext(requestedAudioChannels: MirageAudioChannelLayout.surround51.channelCount)
        #expect(await context.getRequestedAudioChannelCount() == MirageAudioChannelLayout.surround51.channelCount)
    }

    @Test("Setter clamps channel count to supported range")
    func setterClampsRequestedChannelCount() async {
        let context = makeContext(requestedAudioChannels: MirageAudioChannelLayout.stereo.channelCount)
        await context.setRequestedAudioChannelCount(0)
        #expect(await context.getRequestedAudioChannelCount() == 1)

        await context.setRequestedAudioChannelCount(99)
        #expect(await context.getRequestedAudioChannelCount() == 8)
    }

    private func makeContext(
        requestedAudioChannels: Int = MirageAudioChannelLayout.stereo.channelCount
    ) -> StreamContext {
        StreamContext(
            streamID: 1,
            windowID: 1,
            encoderConfig: MirageEncoderConfiguration(targetFrameRate: 60),
            requestedAudioChannelCount: requestedAudioChannels
        )
    }
}
#endif
