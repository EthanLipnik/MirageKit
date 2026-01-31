//
//  StreamContext+Audio.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/31/26.
//
//  Audio capture hookups for stream contexts.
//

import Foundation

#if os(macOS)
extension StreamContext {
    func setAudioSampleHandler(_ handler: (@Sendable (AudioSampleBuffer) -> Void)?) async {
        await captureEngine?.setAudioSampleHandler(handler)
    }
}
#endif
