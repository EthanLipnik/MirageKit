//
//  MirageRenderAdmission.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/12/26.
//
//  Render admission policy and lock-protected in-flight accounting.
//

import Foundation

enum MirageRenderAdmissionPolicy {
    static func effectiveInFlightCap(targetFPS: Int, maximumDrawableCount: Int) -> Int {
        // 60Hz streams at 5K frequently exceed one-frame render latency; 3 in-flight
        // drawables prevents artificial admission stalls when the layer can support it.
        let desiredInFlight = targetFPS >= 120 ? 3 : 3
        return max(1, min(desiredInFlight, maximumDrawableCount))
    }
}

final class MirageRenderAdmissionCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var inFlightRenders: Int = 0

    @discardableResult
    func tryAcquire(limit: Int) -> Bool {
        let clampedLimit = max(1, limit)
        lock.lock()
        defer { lock.unlock() }
        guard inFlightRenders < clampedLimit else { return false }
        inFlightRenders &+= 1
        return true
    }

    @discardableResult
    func release() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard inFlightRenders > 0 else { return false }
        inFlightRenders -= 1
        return true
    }

    func reset() {
        lock.lock()
        inFlightRenders = 0
        lock.unlock()
    }

    func snapshot() -> Int {
        lock.lock()
        let value = inFlightRenders
        lock.unlock()
        return value
    }
}

/// Prevents stale frame presentation when concurrent drawable waits complete out-of-order.
final class MirageRenderSequenceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var latestRequestedSequence: UInt64 = 0
    private var latestPresentedSequence: UInt64 = 0

    func reset() {
        lock.lock()
        latestRequestedSequence = 0
        latestPresentedSequence = 0
        lock.unlock()
    }

    func noteRequested(_ sequence: UInt64) {
        lock.lock()
        // Frame-cache resets restart sequence numbering at 1.
        // Any backward jump indicates a new sequence space.
        if sequence < latestRequestedSequence || sequence < latestPresentedSequence {
            latestRequestedSequence = 0
            latestPresentedSequence = 0
        }
        if sequence > latestRequestedSequence {
            latestRequestedSequence = sequence
        }
        lock.unlock()
    }

    func notePresented(_ sequence: UInt64) {
        lock.lock()
        if sequence > latestPresentedSequence {
            latestPresentedSequence = sequence
        }
        lock.unlock()
    }

    func isStale(_ sequence: UInt64) -> Bool {
        lock.lock()
        let stale = sequence <= latestPresentedSequence
        lock.unlock()
        return stale
    }
}
