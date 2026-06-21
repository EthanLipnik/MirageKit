//
//  HostAudioCaptureLevelState.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 6/20/26.
//

import Foundation

#if os(macOS)

struct HostAudioCaptureLevelState {
    var silentDurationSeconds: Double = 0
    var observedNonSilentCapture = false
    var loggedPersistentSilence = false
}

#endif
