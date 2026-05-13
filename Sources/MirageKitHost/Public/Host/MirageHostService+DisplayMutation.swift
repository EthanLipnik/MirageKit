//
//  MirageHostService+DisplayMutation.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/9/26.
//

import MirageKit

#if os(macOS)
extension MirageHostService {
    /// Runs an operation while holding the shared virtual-display mutation lease.
    func withHostDisplayMutation<T>(
        kind: VirtualDisplayMutationKind,
        operation: () async -> T
    ) async -> T {
        let lease = await VirtualDisplayMutationCoordinator.shared.acquire(kind: kind)
        let result = await operation()
        await VirtualDisplayMutationCoordinator.shared.release(lease)
        return result
    }
}

#endif
