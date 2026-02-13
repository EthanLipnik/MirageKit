//
//  MirageRenderScheduler.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/5/26.
//
//  Display-link-gated render scheduler for decode-accurate presentation.
//

import Foundation
import MirageKit

#if os(iOS) || os(visionOS)
import QuartzCore
#endif

#if os(macOS)
import CoreVideo
#endif

@MainActor
final class MirageRenderScheduler {
    private weak var view: MirageMetalView?
    private var targetFPS: Int = 60
    private var lastTickTime: CFAbsoluteTime = 0

    private var presentedSequence: UInt64 = 0
    private var lastPresentedDecodeTime: CFAbsoluteTime = 0
    private var decodedCount: UInt64 = 0
    private var presentedCount: UInt64 = 0
    private var tickCount: UInt64 = 0
    private var lastLogTime: CFAbsoluteTime = 0
    private var redrawPending = false
    private var lastDecodedSequence: UInt64 = 0

    #if os(iOS) || os(visionOS)
    private var displayLink: CADisplayLink?
    #endif

    #if os(macOS)
    private var displayLink: CVDisplayLink?
    private var lastMacTickTime: CFAbsoluteTime = 0
    #endif

    init(view: MirageMetalView) {
        self.view = view
    }

    func start() {
        #if os(iOS) || os(visionOS)
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(handleDisplayLinkTick))
        link.add(to: RunLoop.main, forMode: RunLoop.Mode.common)
        displayLink = link
        applyTargetFPS()
        #elseif os(macOS)
        guard displayLink == nil else { return }
        var link: CVDisplayLink?
        guard CVDisplayLinkCreateWithActiveCGDisplays(&link) == kCVReturnSuccess,
              let link else {
            MirageLogger.error(.renderer, "Failed to create CVDisplayLink")
            return
        }

        let callback: CVDisplayLinkOutputCallback = { _, _, _, _, _, userInfo in
            guard let userInfo else { return kCVReturnError }
            let scheduler = Unmanaged<MirageRenderScheduler>.fromOpaque(userInfo).takeUnretainedValue()
            scheduler.handleMacDisplayLinkTick()
            return kCVReturnSuccess
        }

        guard CVDisplayLinkSetOutputCallback(
            link,
            callback,
            Unmanaged.passUnretained(self).toOpaque()
        ) == kCVReturnSuccess else {
            MirageLogger.error(.renderer, "Failed to configure CVDisplayLink callback")
            return
        }

        displayLink = link
        if CVDisplayLinkStart(link) != kCVReturnSuccess {
            MirageLogger.error(.renderer, "Failed to start CVDisplayLink")
            displayLink = nil
        }
        #endif
    }

    func stop() {
        #if os(iOS) || os(visionOS)
        displayLink?.invalidate()
        displayLink = nil
        #elseif os(macOS)
        if let displayLink {
            CVDisplayLinkStop(displayLink)
            self.displayLink = nil
        }
        #endif
    }

    func updateTargetFPS(_ fps: Int) {
        targetFPS = fps >= 120 ? 120 : 60
        applyTargetFPS()
    }

    func reset() {
        lastTickTime = 0
        presentedSequence = 0
        lastPresentedDecodeTime = 0
        decodedCount = 0
        presentedCount = 0
        tickCount = 0
        lastLogTime = 0
        redrawPending = false
        #if os(macOS)
        lastMacTickTime = 0
        #endif
        if let streamID = view?.streamID {
            lastDecodedSequence = MirageFrameCache.shared.latestSequence(for: streamID)
        } else {
            lastDecodedSequence = 0
        }
    }

    func notePresented(sequence: UInt64, decodeTime: CFAbsoluteTime) {
        guard sequence > presentedSequence else { return }
        presentedCount &+= 1
        presentedSequence = sequence
        lastPresentedDecodeTime = decodeTime
    }

    func requestRedraw() {
        redrawPending = true
    }

    /// Decode-driven fallback tick. This keeps render cadence stable when display-link
    /// callbacks are throttled or delayed under UI/system load.
    func requestDecodeDrivenTick() {
        let now = CFAbsoluteTimeGetCurrent()
        let minInterval = 1.0 / Double(max(1, targetFPS))
        // Skip if we already ticked recently (display-link or decode-driven).
        guard lastTickTime == 0 || now - lastTickTime >= minInterval * 0.95 else { return }
        processTick(now: now)
    }

    #if os(iOS) || os(visionOS)
    @objc private func handleDisplayLinkTick() {
        let now = CFAbsoluteTimeGetCurrent()
        let minInterval = 1.0 / Double(max(1, targetFPS))
        // Avoid double-driving when decode-driven fallback already ticked this interval.
        if lastTickTime > 0, now - lastTickTime < minInterval * 0.5 {
            return
        }
        processTick(now: now)
    }

    private func applyTargetFPS() {
        guard let displayLink else { return }
        let fps = Float(targetFPS)
        displayLink.preferredFrameRateRange = CAFrameRateRange(
            minimum: fps,
            maximum: fps,
            preferred: fps
        )
    }
    #endif

    #if os(macOS)
    private func applyTargetFPS() {}

    private nonisolated func handleMacDisplayLinkTick() {
        Task { @MainActor [weak self] in
            self?.handleMacTickOnMain()
        }
    }

    private func handleMacTickOnMain() {
        let now = CFAbsoluteTimeGetCurrent()
        let minInterval = 1.0 / Double(max(1, targetFPS))
        if lastMacTickTime > 0, now - lastMacTickTime < minInterval {
            return
        }
        lastMacTickTime = now
        processTick(now: now)
    }
    #endif

    private func processTick(now: CFAbsoluteTime) {
        lastTickTime = now
        tickCount &+= 1

        if let view {
            if let streamID = view.streamID {
                let latestSequence = MirageFrameCache.shared.latestSequence(for: streamID)
                if latestSequence > lastDecodedSequence {
                    decodedCount &+= latestSequence &- lastDecodedSequence
                    lastDecodedSequence = latestSequence
                }

                let hasUnpresentedFrame = latestSequence > presentedSequence
                let queueDepth = MirageFrameCache.shared.queueDepth(for: streamID)
                if redrawPending || hasUnpresentedFrame || queueDepth > 0 {
                    redrawPending = false
                    view.renderSchedulerTick()
                    // Catch-up burst for 60Hz streams: if decode runs ahead of display ticks,
                    // allow one extra draw this tick to close the gap without waiting a full
                    // display-link interval.
                    if targetFPS <= 60 {
                        let backlogAfterPrimaryDraw = MirageFrameCache.shared.queueDepth(for: streamID)
                        if backlogAfterPrimaryDraw >= 4 {
                            view.renderSchedulerTick()
                        }
                    }
                }
            } else if redrawPending {
                redrawPending = false
                view.renderSchedulerTick()
            }
        }

        logIfNeeded(now: now)
    }

    private func logIfNeeded(now: CFAbsoluteTime) {
        guard MirageLogger.isEnabled(.renderer) else {
            if lastLogTime == 0 { lastLogTime = now }
            return
        }
        if lastLogTime == 0 {
            lastLogTime = now
            return
        }
        let elapsed = now - lastLogTime
        guard elapsed >= 2.0 else { return }

        let tickFPS = Double(tickCount) / elapsed
        let decodedFPS = Double(decodedCount) / elapsed
        let presentedFPS = Double(presentedCount) / elapsed
        let presentAgeMs = lastPresentedDecodeTime > 0 ? (now - lastPresentedDecodeTime) * 1000 : 0

        var queueDepth = 0
        var oldestAgeMs: Double = 0
        if let streamID = view?.streamID {
            queueDepth = MirageFrameCache.shared.queueDepth(for: streamID)
            oldestAgeMs = MirageFrameCache.shared.oldestAgeMs(for: streamID)
        }

        let tickText = tickFPS.formatted(.number.precision(.fractionLength(1)))
        let decodedText = decodedFPS.formatted(.number.precision(.fractionLength(1)))
        let presentedText = presentedFPS.formatted(.number.precision(.fractionLength(1)))
        let presentAgeText = presentAgeMs.formatted(.number.precision(.fractionLength(1)))
        let oldestAgeText = oldestAgeMs.formatted(.number.precision(.fractionLength(1)))

        MirageLogger
            .renderer(
                "Render sync: ticks=\(tickText)fps decoded=\(decodedText)fps presented=\(presentedText)fps " +
                    "queueDepth=\(queueDepth) oldest=\(oldestAgeText)ms age=\(presentAgeText)ms"
            )

        decodedCount = 0
        presentedCount = 0
        tickCount = 0
        lastLogTime = now
    }
}
