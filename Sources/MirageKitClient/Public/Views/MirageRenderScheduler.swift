//
//  MirageRenderScheduler.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/5/26.
//
//  CADisplayLink-gated render scheduler for decode-accurate presentation.
//

import Foundation
import MirageKit

#if os(iOS) || os(visionOS)
import QuartzCore

@MainActor
final class MirageRenderScheduler {
    private weak var view: MirageMetalView?
    private var displayLink: CADisplayLink?
    private var targetFPS: Int = 60

    private var pendingSequence: UInt64 = 0
    private var pendingDecodeTime: CFAbsoluteTime = 0
    private var presentedSequence: UInt64 = 0
    private var lastPresentedDecodeTime: CFAbsoluteTime = 0
    private var decodedCount: UInt64 = 0
    private var presentedCount: UInt64 = 0
    private var tickCount: UInt64 = 0
    private var lastLogTime: CFAbsoluteTime = 0
    private var redrawPending = false

    init(view: MirageMetalView) {
        self.view = view
    }

    func start() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(handleTick))
        link.add(to: .main, forMode: .common)
        displayLink = link
        applyTargetFPS()
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }

    func updateTargetFPS(_ fps: Int) {
        targetFPS = fps >= 120 ? 120 : 60
        applyTargetFPS()
    }

    func reset() {
        pendingSequence = 0
        pendingDecodeTime = 0
        presentedSequence = 0
        lastPresentedDecodeTime = 0
        decodedCount = 0
        presentedCount = 0
        tickCount = 0
        lastLogTime = 0
        redrawPending = false
    }

    func notePending(sequence: UInt64, decodeTime: CFAbsoluteTime) {
        guard sequence > pendingSequence else { return }
        decodedCount &+= 1
        pendingSequence = sequence
        pendingDecodeTime = decodeTime
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

    @objc private func handleTick() {
        let now = CFAbsoluteTimeGetCurrent()
        tickCount &+= 1
        if let view, pendingSequence > presentedSequence || redrawPending {
            redrawPending = false
            view.renderSchedulerTick()
        }
        logIfNeeded(now: now)
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
        let ageMs = lastPresentedDecodeTime > 0 ? (now - lastPresentedDecodeTime) * 1000 : 0

        let tickText = tickFPS.formatted(.number.precision(.fractionLength(1)))
        let decodedText = decodedFPS.formatted(.number.precision(.fractionLength(1)))
        let presentedText = presentedFPS.formatted(.number.precision(.fractionLength(1)))
        let ageText = ageMs.formatted(.number.precision(.fractionLength(1)))

        MirageLogger.renderer(
            "Render sync: ticks=\(tickText)fps decoded=\(decodedText)fps presented=\(presentedText)fps age=\(ageText)ms"
        )

        decodedCount = 0
        presentedCount = 0
        tickCount = 0
        lastLogTime = now
    }
}
#endif
