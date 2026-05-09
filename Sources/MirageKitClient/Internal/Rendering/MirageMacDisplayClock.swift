//
//  MirageMacDisplayClock.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/5/26.
//
//  CVDisplayLink adapter for macOS sample-buffer presentation pacing.
//

import CoreVideo
import CoreGraphics
import Foundation
import QuartzCore

#if os(macOS)
final class MirageMacDisplayClock: @unchecked Sendable {
    private let lock = NSLock()
    private var displayLink: CVDisplayLink?
    private var displayID: CGDirectDisplayID?
    private var targetFPS: Int = 60
    private var lastEmittedTickTime: CFTimeInterval = 0
    private var tickHandler: (@Sendable (CFTimeInterval) -> Void)?

    deinit {
        stop()
    }

    func start(
        targetFPS: Int,
        displayID: CGDirectDisplayID?,
        tickHandler: @escaping @Sendable (CFTimeInterval) -> Void
    ) {
        let normalizedTargetFPS = Self.normalizedTargetFPS(targetFPS)
        let oldLink: CVDisplayLink?

        lock.lock()
        if displayLink != nil, self.displayID == displayID {
            self.targetFPS = normalizedTargetFPS
            self.tickHandler = tickHandler
            lock.unlock()
            return
        }
        oldLink = displayLink
        self.displayLink = nil
        self.displayID = displayID
        self.targetFPS = normalizedTargetFPS
        self.tickHandler = tickHandler
        self.lastEmittedTickTime = 0
        lock.unlock()

        Self.stop(link: oldLink)

        guard let createdLink = Self.createDisplayLink(displayID: displayID) else {
            lock.lock()
            if self.displayID == displayID {
                self.tickHandler = nil
            }
            lock.unlock()
            return
        }

        CVDisplayLinkSetOutputCallback(
            createdLink,
            Self.outputCallback,
            Unmanaged.passUnretained(self).toOpaque()
        )

        lock.lock()
        displayLink = createdLink
        lock.unlock()
        CVDisplayLinkStart(createdLink)
    }

    func start(
        targetFPS: Int,
        tickHandler: @escaping @Sendable (CFTimeInterval) -> Void
    ) {
        start(targetFPS: targetFPS, displayID: nil, tickHandler: tickHandler)
    }

    func updateTargetFPS(_ fps: Int) {
        lock.lock()
        targetFPS = Self.normalizedTargetFPS(fps)
        lock.unlock()
    }

    func updateTargetFPS(_ fps: Int, displayID: CGDirectDisplayID?) {
        lock.lock()
        let currentHandler = tickHandler
        let shouldRestart = displayLink != nil && Self.shouldRestartDisplayLink(
            currentDisplayID: self.displayID,
            newDisplayID: displayID
        )
        lock.unlock()

        guard shouldRestart, let currentHandler else {
            updateTargetFPS(fps)
            return
        }

        start(targetFPS: fps, displayID: displayID, tickHandler: currentHandler)
    }

    func stop() {
        let link: CVDisplayLink?
        lock.lock()
        link = displayLink
        displayLink = nil
        displayID = nil
        tickHandler = nil
        lastEmittedTickTime = 0
        lock.unlock()

        Self.stop(link: link)
    }

    static func shouldEmitTick(
        lastEmittedTickTime: CFTimeInterval,
        now: CFTimeInterval,
        targetFPS: Int
    ) -> Bool {
        guard lastEmittedTickTime > 0 else { return true }
        let interval = 1.0 / Double(normalizedTargetFPS(targetFPS))
        return now - lastEmittedTickTime >= interval * 0.80
    }

    private static func normalizedTargetFPS(_ fps: Int) -> Int {
        max(1, min(240, fps))
    }

    static func shouldRestartDisplayLink(
        currentDisplayID: CGDirectDisplayID?,
        newDisplayID: CGDirectDisplayID?
    ) -> Bool {
        currentDisplayID != newDisplayID
    }

    private static func createDisplayLink(displayID: CGDirectDisplayID?) -> CVDisplayLink? {
        var createdLink: CVDisplayLink?
        if let displayID {
            let status = CVDisplayLinkCreateWithCGDisplay(displayID, &createdLink)
            if status == kCVReturnSuccess, createdLink != nil {
                return createdLink
            }
        }

        var status = CVDisplayLinkCreateWithActiveCGDisplays(&createdLink)
        if status == kCVReturnSuccess, createdLink != nil {
            return createdLink
        }

        status = CVDisplayLinkCreateWithCGDisplay(CGMainDisplayID(), &createdLink)
        guard status == kCVReturnSuccess else { return nil }
        return createdLink
    }

    private static func stop(link: CVDisplayLink?) {
        guard let link else { return }
        CVDisplayLinkStop(link)
        CVDisplayLinkSetOutputCallback(link, nil, nil)
    }

    private static func referenceTime(from timestamp: CVTimeStamp) -> CFTimeInterval? {
        guard timestamp.hostTime > 0 else { return nil }
        let frequency = CVGetHostClockFrequency()
        guard frequency > 0 else { return nil }
        return CFTimeInterval(timestamp.hostTime) / frequency
    }

    private func handleDisplayLinkOutput(outputTime: CVTimeStamp) {
        let referenceTime = Self.referenceTime(from: outputTime) ?? CACurrentMediaTime()
        let handler: (@Sendable (CFTimeInterval) -> Void)?

        lock.lock()
        guard Self.shouldEmitTick(
            lastEmittedTickTime: lastEmittedTickTime,
            now: referenceTime,
            targetFPS: targetFPS
        ) else {
            lock.unlock()
            return
        }
        lastEmittedTickTime = referenceTime
        handler = tickHandler
        lock.unlock()

        handler?(referenceTime)
    }

    private static let outputCallback: CVDisplayLinkOutputCallback = { _, _, outputTime, _, _, context in
        guard let context else { return kCVReturnSuccess }
        let clock = Unmanaged<MirageMacDisplayClock>.fromOpaque(context).takeUnretainedValue()
        clock.handleDisplayLinkOutput(outputTime: outputTime.pointee)
        return kCVReturnSuccess
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
