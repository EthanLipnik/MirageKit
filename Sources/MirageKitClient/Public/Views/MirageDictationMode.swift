//
//  MirageDictationMode.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/10/26.
//
//  Dictation quality and latency behavior selection.
//

import Foundation

/// Dictation quality and latency mode.
public enum MirageDictationMode: String, CaseIterable, Codable, Sendable {
    /// UserDefaults key for the selected dictation behavior.
    public static let defaultsKey = "dictationMode"

    /// Prefer low-latency partial results while speaking.
    case realTime
    /// Prefer higher quality final transcription.
    case best

    /// User-visible mode name.
    public var displayName: String {
        switch self {
        case .realTime:
            "Real Time"
        case .best:
            "Best"
        }
    }
}
