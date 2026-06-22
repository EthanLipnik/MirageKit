//
//  MirageMacDisplayClock.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/5/26.
//
//  CVDisplayLink adapter for macOS sample-buffer presentation pacing.
//

#if os(macOS)
import AppKit
import Foundation
import MirageKit
import QuartzCore

@MainActor
final class MirageMacDisplayClock: NSObject, @unchecked Sendable {
    private let lock = NSLock()
    private var displayLink: CADisplayLink?
    private var targetFPS: Int = 60
    private var lastEmittedTickTime: CFTimeInterval = 0
    private var tickHandler: (@Sendable (CFTimeInterval) -> Void)?

    isolated deinit {
        stop()
    }

    func start(
        in view: NSView,
        targetFPS: Int,
        tickHandler: @escaping @Sendable (CFTimeInterval) -> Void
    ) {
        let normalizedTargetFPS = MirageStreamCadenceTarget.normalizedFPS(targetFPS)
        lock.lock()
        let alreadyRunning: Bool
        do {
            defer { lock.unlock() }
            self.targetFPS = normalizedTargetFPS
            self.tickHandler = tickHandler
            alreadyRunning = displayLink != nil
        }

        guard !alreadyRunning else { return }

        let createdLink = view.displayLink(target: self, selector: #selector(displayLinkDidTick(_:)))
        createdLink.preferredFrameRateRange = Self.frameRateRange(for: normalizedTargetFPS)
        createdLink.add(to: .main, forMode: .common)

        lock.lock()
        do {
            defer { lock.unlock() }
            displayLink = createdLink
            lastEmittedTickTime = 0
        }
    }

    func updateTargetFPS(_ fps: Int) {
        let normalizedTargetFPS = MirageStreamCadenceTarget.normalizedFPS(fps)
        let link: CADisplayLink?
        lock.lock()
        targetFPS = normalizedTargetFPS
        link = displayLink
        lock.unlock()
        link?.preferredFrameRateRange = Self.frameRateRange(for: normalizedTargetFPS)
    }

    func stop() {
        let link: CADisplayLink?
        lock.lock()
        link = displayLink
        displayLink = nil
        tickHandler = nil
        lastEmittedTickTime = 0
        lock.unlock()

        link?.invalidate()
    }

    nonisolated static func shouldEmitTick(
        lastEmittedTickTime: CFTimeInterval,
        now: CFTimeInterval,
        targetFPS: Int
    ) -> Bool {
        guard lastEmittedTickTime > 0 else { return true }
        let interval = 1.0 / Double(MirageStreamCadenceTarget.normalizedFPS(targetFPS))
        return now - lastEmittedTickTime >= interval * 0.90
    }

    nonisolated private static func frameRateRange(for targetFPS: Int) -> CAFrameRateRange {
        let preferred = Float(MirageStreamCadenceTarget.normalizedFPS(targetFPS))
        return CAFrameRateRange(minimum: preferred, maximum: preferred, preferred: preferred)
    }

    @objc private func displayLinkDidTick(_ displayLink: CADisplayLink) {
        let now = displayLink.timestamp
        let handler: (@Sendable (CFTimeInterval) -> Void)?

        lock.lock()
        do {
            defer { lock.unlock() }
            guard Self.shouldEmitTick(
                lastEmittedTickTime: lastEmittedTickTime,
                now: now,
                targetFPS: targetFPS
            ) else {
                handler = nil
                return
            }
            lastEmittedTickTime = now
            handler = tickHandler
        }

        handler?(now)
    }
}

final class MirageMacDisplayTickRelay: @unchecked Sendable {
    typealias EnqueueDelivery = @Sendable (@escaping @MainActor () -> Void) -> Void

    private let lock = NSLock()
    private let enqueueDelivery: EnqueueDelivery
    private let deliver: @MainActor (CFTimeInterval) -> Void
    private var latestReferenceTime: CFTimeInterval?
    private var deliveryPending = false
    private var coalescedCallbackCount: UInt64 = 0

    init(
        enqueueDelivery: @escaping EnqueueDelivery = { action in
            Task { @MainActor in
                action()
            }
        },
        deliver: @escaping @MainActor (CFTimeInterval) -> Void
    ) {
        self.enqueueDelivery = enqueueDelivery
        self.deliver = deliver
    }

    func receive(referenceTime: CFTimeInterval) {
        let shouldSchedule: Bool
        lock.lock()
        latestReferenceTime = referenceTime
        shouldSchedule = !deliveryPending
        if shouldSchedule {
            deliveryPending = true
        } else {
            coalescedCallbackCount &+= 1
        }
        lock.unlock()

        guard shouldSchedule else { return }
        enqueueDelivery { [weak self] in
            self?.deliverLatest()
        }
    }

    func cancel() {
        lock.lock()
        latestReferenceTime = nil
        deliveryPending = false
        lock.unlock()
    }

    func coalescedCallbackCountSnapshot() -> UInt64 {
        lock.lock()
        let count = coalescedCallbackCount
        lock.unlock()
        return count
    }

    @MainActor
    private func deliverLatest() {
        let referenceTime: CFTimeInterval?
        lock.lock()
        referenceTime = latestReferenceTime
        latestReferenceTime = nil
        deliveryPending = false
        lock.unlock()

        guard let referenceTime else { return }
        deliver(referenceTime)
    }
}
#endif
