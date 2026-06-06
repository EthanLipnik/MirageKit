//
//  MirageSessionBootstrapProgress.swift
//  MirageConnectivity
//
//  Created by Ethan Lipnik on 6/5/26.
//

/// Product-owned authenticated-session bootstrap progress used by client policy before a Loom session is ready.
package struct MirageSessionBootstrapProgress: Sendable, Codable, Equatable {
    package let phase: MirageSessionBootstrapPhase
    package let failureReason: String?

    package init(
        phase: MirageSessionBootstrapPhase,
        failureReason: String? = nil
    ) {
        self.phase = phase
        self.failureReason = failureReason
    }

    package var isFailure: Bool {
        failureReason != nil
    }
}
