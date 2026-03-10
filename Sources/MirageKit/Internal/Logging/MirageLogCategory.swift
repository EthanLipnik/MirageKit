//
//  MirageLogCategory.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/9/26.
//

import Foundation

public enum MirageLogCategory: String, CaseIterable, Sendable {
    case timing
    case metrics
    case capture
    case encoder
    case decoder
    case client
    case host
    case renderer
    case appState
    case windowFilter
    case stream
    case frameAssembly
    case discovery
    case network
    case accessibility
    case windowActivator
    case menuBar
    case bootstrap
    case ssh
    case wol
    case bootstrapHandoff = "bootstrap_handoff"
}
