//
//  MirageMacDisplayClock.swift
//  MirageKitClientPresentation
//
//  Created by Ethan Lipnik on 5/5/26.
//
//  CVDisplayLink adapter for macOS sample-buffer presentation pacing.
//

import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageKit
import MirageMedia
import MirageWire
import CoreVideo
import CoreGraphics
import Foundation
import QuartzCore

#if os(macOS)
package final class MirageMacDisplayClock: @unchecked Sendable {
    private let lock = NSLock()
    private var displayLink: CVDisplayLink?
    private var displayID: CGDirectDisplayID?
    private var targetFPS: Int = 60
    private var lastEmittedTickTime: CFTimeInterval = 0
    private var tickHandler: (@Sendable (CFTimeInterval) -> Void)?

    deinit {
        stop()
    }

    package init() {}

    package func start(
        targetFPS: Int,
        tickHandler: @escaping @Sendable (CFTimeInterval) -> Void
    ) {
        lock.lock()
        let alreadyRunning: Bool
        do {
            defer { lock.unlock() }
            self.targetFPS = MirageMedia.MirageStreamCadenceTarget.normalizedFPS(targetFPS)
            self.tickHandler = tickHandler
            alreadyRunning = displayLink != nil
        }

        guard !alreadyRunning else { return }

        var createdLink: CVDisplayLink?
        var status = CVDisplayLinkCreateWithActiveCGDisplays(&createdLink)
        if status != kCVReturnSuccess || createdLink == nil {
            status = CVDisplayLinkCreateWithCGDisplay(CGMainDisplayID(), &createdLink)
            guard status == kCVReturnSuccess, createdLink != nil else { return }
        }
        guard let createdLink else { return }

        CVDisplayLinkSetOutputCallback(
            createdLink,
            Self.outputCallback,
            Unmanaged.passUnretained(self).toOpaque()
        )

        lock.lock()
        do {
            defer { lock.unlock() }
            displayLink = createdLink
            lastEmittedTickTime = 0
        }
        CVDisplayLinkStart(createdLink)
    }

    package func updateTargetFPS(_ fps: Int) {
        lock.lock()
        defer { lock.unlock() }
        targetFPS = MirageMedia.MirageStreamCadenceTarget.normalizedFPS(fps)
    }

    package func updateTargetFPS(_ fps: Int, displayID: CGDirectDisplayID?) {
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

    package func start(
        targetFPS: Int,
        displayID: CGDirectDisplayID?,
        tickHandler: @escaping @Sendable (CFTimeInterval) -> Void
    ) {
        let normalizedTargetFPS = MirageMedia.MirageStreamCadenceTarget.normalizedFPS(targetFPS)
        let oldLink: CVDisplayLink?

        lock.lock()
        if displayLink != nil, self.displayID == displayID {
            self.targetFPS = normalizedTargetFPS
            self.tickHandler = tickHandler
            lock.unlock()
            return
        }
        oldLink = displayLink
        displayLink = nil
        self.displayID = displayID
        self.targetFPS = normalizedTargetFPS
        self.tickHandler = tickHandler
        lock.unlock()

        Self.stop(link: oldLink)

        let previousDisplayID = displayID
        var createdLink: CVDisplayLink?
        if let displayID {
            let status = CVDisplayLinkCreateWithCGDisplay(displayID, &createdLink)
            if status != kCVReturnSuccess {
                createdLink = nil
            }
        }
        if createdLink == nil {
            var status = CVDisplayLinkCreateWithActiveCGDisplays(&createdLink)
            if status != kCVReturnSuccess || createdLink == nil {
                status = CVDisplayLinkCreateWithCGDisplay(CGMainDisplayID(), &createdLink)
                guard status == kCVReturnSuccess, createdLink != nil else {
                    lock.lock()
                    if self.displayID == previousDisplayID {
                        self.tickHandler = nil
                    }
                    lock.unlock()
                    return
                }
            }
        }
        guard let createdLink else { return }

        CVDisplayLinkSetOutputCallback(
            createdLink,
            Self.outputCallback,
            Unmanaged.passUnretained(self).toOpaque()
        )

        lock.lock()
        displayLink = createdLink
        lastEmittedTickTime = 0
        lock.unlock()
        CVDisplayLinkStart(createdLink)
    }

    package func stop() {
        let link: CVDisplayLink?
        lock.lock()
        do {
            defer { lock.unlock() }
            link = displayLink
            displayLink = nil
            displayID = nil
            tickHandler = nil
            lastEmittedTickTime = 0
        }

        Self.stop(link: link)
    }

    package static func shouldEmitTick(
        lastEmittedTickTime: CFTimeInterval,
        now: CFTimeInterval,
        targetFPS: Int
    ) -> Bool {
        guard lastEmittedTickTime > 0 else { return true }
        let interval = 1.0 / Double(MirageMedia.MirageStreamCadenceTarget.normalizedFPS(targetFPS))
        return now - lastEmittedTickTime >= interval * 0.90
    }

    package static func shouldRestartDisplayLink(
        currentDisplayID: CGDirectDisplayID?,
        newDisplayID: CGDirectDisplayID?
    ) -> Bool {
        currentDisplayID != newDisplayID
    }

    private static func stop(link: CVDisplayLink?) {
        guard let link else { return }
        CVDisplayLinkStop(link)
        CVDisplayLinkSetOutputCallback(link, nil, nil)
    }

    private func handleDisplayLinkOutput() {
        let now = CACurrentMediaTime()
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

    private static let outputCallback: CVDisplayLinkOutputCallback = { _, _, _, _, _, context in
        guard let context else { return kCVReturnSuccess }
        let clock = Unmanaged<MirageMacDisplayClock>.fromOpaque(context).takeUnretainedValue()
        clock.handleDisplayLinkOutput()
        return kCVReturnSuccess
    }
}

package final class MirageMacDisplayTickRelay: @unchecked Sendable {
    package typealias EnqueueDelivery = @Sendable (@escaping @MainActor () -> Void) -> Void

    private let lock = NSLock()
    private let enqueueDelivery: EnqueueDelivery
    private let deliver: @MainActor (CFTimeInterval) -> Void
    private var latestReferenceTime: CFTimeInterval?
    private var deliveryPending = false
    private var coalescedCallbackCount: UInt64 = 0

    package init(
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

    package func receive(referenceTime: CFTimeInterval) {
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

    package func cancel() {
        lock.lock()
        latestReferenceTime = nil
        deliveryPending = false
        lock.unlock()
    }

    package func coalescedCallbackCountSnapshot() -> UInt64 {
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
