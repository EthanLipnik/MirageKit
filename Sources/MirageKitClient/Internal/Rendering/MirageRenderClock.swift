//
//  MirageRenderClock.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/16/26.
//
//  Display clock abstraction for client rendering.
//

import Foundation

#if os(macOS)
import CoreVideo
#endif

protocol MirageRenderClock: AnyObject {
    var onPulse: (@Sendable (_ now: CFAbsoluteTime) -> Void)? { get set }
    func start()
    func stop()
    func updateTargetFPS(_ fps: Int)
}

enum MirageRenderClockFactory {
    static func make() -> MirageRenderClock {
        #if os(iOS) || os(visionOS)
        return MirageDisplayLinkRenderClock()
        #elseif os(macOS)
        return MirageCVDisplayLinkRenderClock()
        #else
        fatalError("Unsupported platform")
        #endif
    }
}

#if os(iOS) || os(visionOS)
final class MirageDisplayLinkRenderClock: MirageRenderClock {
    var onPulse: (@Sendable (CFAbsoluteTime) -> Void)? {
        didSet {
            callbackRelay.setOnPulse(onPulse)
        }
    }

    private let driver = MirageRenderDriver()
    private let callbackRelay = CallbackRelay()

    private final class CallbackRelay: @unchecked Sendable {
        private let lock = NSLock()
        private var onPulse: (@Sendable (CFAbsoluteTime) -> Void)?

        func setOnPulse(_ callback: (@Sendable (CFAbsoluteTime) -> Void)?) {
            lock.lock()
            onPulse = callback
            lock.unlock()
        }

        func invoke(_ now: CFAbsoluteTime) {
            lock.lock()
            let callback = onPulse
            lock.unlock()
            callback?(now)
        }
    }

    init() {
        driver.onPulse = { [callbackRelay] now in
            callbackRelay.invoke(now)
        }
    }

    func start() {
        driver.start()
    }

    func stop() {
        driver.stop()
    }

    func updateTargetFPS(_ fps: Int) {
        driver.updateTargetFPS(fps)
    }
}
#endif

#if os(macOS)
final class MirageCVDisplayLinkRenderClock: MirageRenderClock {
    var onPulse: (@Sendable (CFAbsoluteTime) -> Void)?

    private let lock = NSLock()
    private var displayLink: CVDisplayLink?
    private var targetFPS: Int = 60
    private var lastPulseTime: CFAbsoluteTime = 0

    func start() {
        lock.lock()
        if displayLink != nil {
            lock.unlock()
            return
        }

        var created: CVDisplayLink?
        guard CVDisplayLinkCreateWithActiveCGDisplays(&created) == kCVReturnSuccess,
              let created else {
            lock.unlock()
            return
        }

        let callback: CVDisplayLinkOutputCallback = { _, _, _, _, _, userInfo in
            guard let userInfo else { return kCVReturnError }
            let clock = Unmanaged<MirageCVDisplayLinkRenderClock>.fromOpaque(userInfo).takeUnretainedValue()
            clock.handleDisplayLinkPulse()
            return kCVReturnSuccess
        }

        guard CVDisplayLinkSetOutputCallback(
            created,
            callback,
            Unmanaged.passUnretained(self).toOpaque()
        ) == kCVReturnSuccess else {
            lock.unlock()
            return
        }

        displayLink = created
        lock.unlock()

        if CVDisplayLinkStart(created) != kCVReturnSuccess {
            stop()
        }
    }

    func stop() {
        lock.lock()
        let link = displayLink
        displayLink = nil
        lastPulseTime = 0
        lock.unlock()

        if let link {
            CVDisplayLinkStop(link)
        }
    }

    func updateTargetFPS(_ fps: Int) {
        lock.lock()
        targetFPS = fps >= 120 ? 120 : 60
        lock.unlock()
    }

    private func handleDisplayLinkPulse() {
        let now = CFAbsoluteTimeGetCurrent()

        lock.lock()
        let currentTarget = targetFPS
        let previousPulse = lastPulseTime
        let minInterval = 1.0 / Double(max(1, currentTarget))
        if previousPulse > 0, now - previousPulse < minInterval {
            lock.unlock()
            return
        }
        lastPulseTime = now
        let callback = onPulse
        lock.unlock()

        callback?(now)
    }
}
#endif
