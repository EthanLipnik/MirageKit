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
    private var targetFPS: Int = 60
    private var lastEmittedTickTime: CFTimeInterval = 0
    private var tickHandler: (@Sendable (CFTimeInterval) -> Void)?

    deinit {
        stop()
    }

    func start(
        targetFPS: Int,
        tickHandler: @escaping @Sendable (CFTimeInterval) -> Void
    ) {
        lock.lock()
        self.targetFPS = Self.normalizedTargetFPS(targetFPS)
        self.tickHandler = tickHandler
        let alreadyRunning = displayLink != nil
        lock.unlock()

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
        displayLink = createdLink
        lastEmittedTickTime = 0
        lock.unlock()
        CVDisplayLinkStart(createdLink)
    }

    func updateTargetFPS(_ fps: Int) {
        lock.lock()
        targetFPS = Self.normalizedTargetFPS(fps)
        lock.unlock()
    }

    func stop() {
        let link: CVDisplayLink?
        lock.lock()
        link = displayLink
        displayLink = nil
        tickHandler = nil
        lastEmittedTickTime = 0
        lock.unlock()

        if let link {
            CVDisplayLinkStop(link)
            CVDisplayLinkSetOutputCallback(link, nil, nil)
        }
    }

    static func shouldEmitTick(
        lastEmittedTickTime: CFTimeInterval,
        now: CFTimeInterval,
        targetFPS: Int
    ) -> Bool {
        guard lastEmittedTickTime > 0 else { return true }
        let interval = 1.0 / Double(normalizedTargetFPS(targetFPS))
        return now - lastEmittedTickTime >= interval * 0.90
    }

    private static func normalizedTargetFPS(_ fps: Int) -> Int {
        max(1, min(240, fps))
    }

    private func handleDisplayLinkOutput() {
        let now = CACurrentMediaTime()
        let handler: (@Sendable (CFTimeInterval) -> Void)?

        lock.lock()
        guard Self.shouldEmitTick(
            lastEmittedTickTime: lastEmittedTickTime,
            now: now,
            targetFPS: targetFPS
        ) else {
            lock.unlock()
            return
        }
        lastEmittedTickTime = now
        handler = tickHandler
        lock.unlock()

        handler?(now)
    }

    private static let outputCallback: CVDisplayLinkOutputCallback = { _, _, _, _, _, context in
        guard let context else { return kCVReturnSuccess }
        let clock = Unmanaged<MirageMacDisplayClock>.fromOpaque(context).takeUnretainedValue()
        clock.handleDisplayLinkOutput()
        return kCVReturnSuccess
    }
}
#endif
