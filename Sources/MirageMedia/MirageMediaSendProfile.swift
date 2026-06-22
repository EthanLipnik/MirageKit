//
//  MirageMediaSendProfile.swift
//  MirageMedia
//
//  Created by Ethan Lipnik on 6/5/26.
//

/// Mirage-owned queued-unreliable send profile.
public enum MirageMediaSendProfile: String, Sendable, Codable, Hashable, CaseIterable {
    case interactiveMedia
    case proximityInteractiveMedia
    case proximityRealtimeDisplay
    case proximityRealtimeDisplaySingleLane
    case interactiveAudio
    case proximityInteractiveAudio
    case priorityInputRealtime
    case priorityInputRealtimeSequenced
    case priorityInputContinuous
    case priorityInputProtected
    case throughputProbe
}
