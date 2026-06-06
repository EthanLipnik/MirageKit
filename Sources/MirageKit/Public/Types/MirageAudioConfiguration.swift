import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageMedia
import MirageWire
//
//  MirageMedia.MirageAudioConfiguration.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/12/26.
//



public extension MirageMedia.MirageAudioConfiguration {
    /// Resolves host-audio policy for a desktop stream mode.
    /// Secondary display streams are video-only because host audio belongs to
    /// unified desktop and app/window streaming, not the synthetic display.
    func resolvedForDesktopStreamMode(_ mode: MirageMedia.MirageDesktopStreamMode) -> MirageMedia.MirageAudioConfiguration {
        guard mode == .secondary, enabled else { return self }
        var configuration = self
        configuration.enabled = false
        return configuration
    }
}
