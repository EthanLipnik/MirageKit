//
//  VirtualDisplayMutationCoordinator.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/8/26.
//
//  Serializes WindowServer-facing virtual display mutations.
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
import Foundation

#if os(macOS)
enum VirtualDisplayMutationKind: String, Sendable {
    case virtualDisplayCreate = "virtual_display_create"
    case virtualDisplayModeUpdate = "virtual_display_mode_update"
    case virtualDisplayDestroy = "virtual_display_destroy"
    case displayMirroring = "display_mirroring"
}

struct VirtualDisplayMutationTimingPolicy: Sendable, Equatable {
    static let defaultSettleDelay: Duration = .milliseconds(180)

    let settleDelay: Duration

    init(settleDelay: Duration = Self.defaultSettleDelay) {
        self.settleDelay = settleDelay
    }
}

struct VirtualDisplayMutationLease: Sendable, Equatable {
    let kind: VirtualDisplayMutationKind
    let sequence: UInt64
}

final class VirtualDisplayMutationCoordinator: @unchecked Sendable {
    static let shared = VirtualDisplayMutationCoordinator()

    private actor Gate {
        private var busy = false
        private var sequence: UInt64 = 0
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func acquire() async -> UInt64 {
            if busy {
                await withCheckedContinuation { continuation in
                    waiters.append(continuation)
                }
            }

            busy = true
            sequence &+= 1
            return sequence
        }

        func release(settleDelay: Duration) async {
            if settleDelay > .zero {
                do {
                    try await Task.sleep(for: settleDelay)
                } catch {
                    // Cancellation still needs to release the mutation lock.
                }
            }

            guard !waiters.isEmpty else {
                busy = false
                return
            }

            waiters.removeFirst().resume()
        }
    }

    private let gate = Gate()
    private let timingPolicy: VirtualDisplayMutationTimingPolicy

    init(timingPolicy: VirtualDisplayMutationTimingPolicy = VirtualDisplayMutationTimingPolicy()) {
        self.timingPolicy = timingPolicy
    }

    func acquire(kind: VirtualDisplayMutationKind) async -> VirtualDisplayMutationLease {
        let sequence = await gate.acquire()
        MirageLogger.debug(.host, "Display mutation started: kind=\(kind.rawValue), sequence=\(sequence)")
        return VirtualDisplayMutationLease(kind: kind, sequence: sequence)
    }

    func release(
        _ lease: VirtualDisplayMutationLease,
        settleDelay: Duration? = nil
    ) async {
        await gate.release(settleDelay: settleDelay ?? timingPolicy.settleDelay)
        MirageLogger.debug(.host, "Display mutation finished: kind=\(lease.kind.rawValue), sequence=\(lease.sequence)")
    }
}
#endif
