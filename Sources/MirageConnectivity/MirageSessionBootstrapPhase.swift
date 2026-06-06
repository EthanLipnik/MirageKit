//
//  MirageSessionBootstrapPhase.swift
//  MirageConnectivity
//
//  Created by Ethan Lipnik on 6/5/26.
//

/// Product-owned bootstrap phase used by connectivity policy before a Loom session is established.
package enum MirageSessionBootstrapPhase: String, Sendable, Codable, Equatable, CaseIterable {
    case idle
    case transportStarting
    case transportReady
    case localHelloSent
    case remoteHelloReceived
    case trustPendingApproval
    case ready
}
