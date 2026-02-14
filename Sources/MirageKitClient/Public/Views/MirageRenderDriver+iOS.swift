//
//  MirageRenderDriver+iOS.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/13/26.
//
//  Dedicated iOS/visionOS render pulse driver on a separate runloop thread.
//

import Foundation
#if os(iOS) || os(visionOS)
import QuartzCore

final class MirageRenderDriver: NSObject {
    typealias PulseHandler = @Sendable (_ now: CFAbsoluteTime) -> Void

    private final class DisplayLinkRelay: NSObject {
        var onTick: (() -> Void)?

        @objc func handleTick(_: CADisplayLink) {
            onTick?()
        }
    }

    private let lock = NSLock()
    private let relay = DisplayLinkRelay()
    private var thread: Thread?
    private var displayLink: CADisplayLink?
    private var targetFPS: Int = 60

    var onPulse: PulseHandler?

    override init() {
        super.init()
        relay.onTick = { [weak self] in
            self?.onPulse?(CFAbsoluteTimeGetCurrent())
        }
    }

    func start() {
        lock.lock()
        if thread != nil {
            lock.unlock()
            return
        }
        let thread = Thread { [weak self] in
            self?.runDriverThread()
        }
        thread.name = "com.mirage.client.render-driver"
        self.thread = thread
        lock.unlock()
        thread.start()
    }

    func stop() {
        lock.lock()
        guard let thread else {
            lock.unlock()
            return
        }
        lock.unlock()
        perform(
            #selector(stopDriverThread),
            on: thread,
            with: nil,
            waitUntilDone: false,
            modes: [RunLoop.Mode.default.rawValue, RunLoop.Mode.common.rawValue]
        )
    }

    func updateTargetFPS(_ fps: Int) {
        let normalized = fps >= 120 ? 120 : 60
        lock.lock()
        targetFPS = normalized
        let thread = self.thread
        lock.unlock()
        guard let thread else { return }
        perform(
            #selector(applyTargetFPSOnDriverThread),
            on: thread,
            with: nil,
            waitUntilDone: false,
            modes: [RunLoop.Mode.default.rawValue, RunLoop.Mode.common.rawValue]
        )
    }

    private func runDriverThread() {
        autoreleasepool {
            let runLoop = RunLoop.current
            let keepAlivePort = Port()
            runLoop.add(keepAlivePort, forMode: .default)

            let link = CADisplayLink(target: relay, selector: #selector(DisplayLinkRelay.handleTick(_:)))
            displayLink = link
            applyTargetFPSOnDriverThread()
            link.add(to: runLoop, forMode: .common)

            while !Thread.current.isCancelled {
                let didRun = runLoop.run(mode: .default, before: .distantFuture)
                if !didRun {
                    break
                }
            }

            link.invalidate()
            lock.lock()
            displayLink = nil
            thread = nil
            lock.unlock()
        }
    }

    @objc private func applyTargetFPSOnDriverThread() {
        guard let displayLink else { return }
        lock.lock()
        let fps = targetFPS
        lock.unlock()
        let hz = Float(fps)
        displayLink.preferredFramesPerSecond = fps
        displayLink.preferredFrameRateRange = CAFrameRateRange(
            minimum: hz,
            maximum: hz,
            preferred: hz
        )
    }

    @objc private func stopDriverThread() {
        Thread.current.cancel()
        displayLink?.invalidate()
        displayLink = nil
        CFRunLoopStop(CFRunLoopGetCurrent())
    }
}
#endif
