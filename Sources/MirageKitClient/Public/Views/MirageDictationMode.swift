//
//  MirageDictationMode.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/10/26.
//
//  Dictation quality and latency behavior selection.
//

import Foundation

public enum MirageDictationMode: String, CaseIterable, Codable, Sendable {
    case realTime
    case best

    public var displayName: String {
        switch self {
        case .realTime:
            "Real Time"
        case .best:
            "Best"
        }
    }
}
