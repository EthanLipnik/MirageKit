//
//  MirageHostService+DisplayMutation.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/9/26.
//


import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageKit
import MirageKitClientPresentation
import MirageMedia
import MirageWire
#if os(macOS)
extension MirageHostService {
    /// Runs an operation while holding the shared virtual-display mutation lease.
    func withHostDisplayMutation<T: Sendable>(
        kind: VirtualDisplayMutationKind,
        operation: @MainActor () async -> T
    ) async -> T {
        await platformVirtualDisplayBackend.withDisplayMutation(
            kind: kind,
            operation: operation
        )
    }
}

#endif
