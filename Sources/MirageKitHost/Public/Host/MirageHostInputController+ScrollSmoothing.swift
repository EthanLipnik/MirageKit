//
//  MirageHostInputController+ScrollSmoothing.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Host input controller extensions.
//

import CoreGraphics
import Foundation
import MirageKit

#if os(macOS)
import AppKit
import ApplicationServices

extension MirageHostInputController {
    // MARK: - Scroll Rate Smoothing (runs on accessibilityQueue)

    func batchScroll(_ event: MirageScrollEvent, _ windowFrame: CGRect, app: MirageApplication?) {
        let now = CACurrentMediaTime()

        if event.phase == .began || event.phase == .ended || event.phase == .cancelled ||
            event.momentumPhase == .began || event.momentumPhase == .ended || event.momentumPhase == .cancelled {
            if event.phase == .began || event.momentumPhase == .began {
                scrollRateX = 0
                scrollRateY = 0
                scrollTargetRateX = 0
                scrollTargetRateY = 0
                scrollRemainderX = 0
                scrollRemainderY = 0
                lastScrollOutputTime = 0
            }
            injectScrollEvent(event, windowFrame, app: app)
            lastScrollInputTime = now
            return
        }

        let dt = now - lastScrollInputTime
        lastScrollInputTime = now

        let effectiveDt = max(0.004, min(dt, 0.1))
        let instantRateX = event.deltaX / CGFloat(effectiveDt)
        let instantRateY = event.deltaY / CGFloat(effectiveDt)

        scrollTargetRateX = instantRateX
        scrollTargetRateY = instantRateY

        scrollContext = (windowFrame, app, event.location, event.modifiers, event.isPrecise)

        if scrollOutputTimer == nil {
            scrollRateX = instantRateX
            scrollRateY = instantRateY
            lastScrollOutputTime = now
            startScrollOutputTimer()
        }
    }

    private func startScrollOutputTimer() {
        scrollOutputTimer?.cancel()

        let timer = DispatchSource.makeTimerSource(queue: accessibilityQueue)
        timer.schedule(
            deadline: .now() + .milliseconds(Int(scrollOutputIntervalMs)),
            repeating: .milliseconds(Int(scrollOutputIntervalMs)),
            leeway: .milliseconds(1)
        )
        timer.setEventHandler { [weak self] in
            self?.scrollOutputTick()
        }
        timer.resume()
        scrollOutputTimer = timer
    }

    private func scrollOutputTick() {
        guard let context = scrollContext else {
            stopScrollOutputTimer()
            return
        }

        let now = CACurrentMediaTime()
        let timeSinceInput = now - lastScrollInputTime

        if timeSinceInput > scrollDecayDelay {
            scrollTargetRateX *= scrollRateDecay
            scrollTargetRateY *= scrollRateDecay
        }

        let dt = max(0.001, min(now - lastScrollOutputTime, 0.05))
        lastScrollOutputTime = now
        let alpha = min(1.0, dt / scrollLerpTimeConstant)
        scrollRateX += (scrollTargetRateX - scrollRateX) * alpha
        scrollRateY += (scrollTargetRateY - scrollRateY) * alpha

        let tickDuration = CGFloat(scrollOutputIntervalMs) / 1000.0
        let deltaX = scrollRateX * tickDuration
        let deltaY = scrollRateY * tickDuration

        scrollRemainderX += deltaX
        scrollRemainderY += deltaY

        let injectX = trunc(scrollRemainderX)
        let injectY = trunc(scrollRemainderY)

        if abs(injectX) >= 1 || abs(injectY) >= 1 {
            scrollRemainderX -= injectX
            scrollRemainderY -= injectY
            injectScrollPixels(Int32(injectX), Int32(injectY), context: context)
        }

        let rateMagnitude = sqrt(scrollRateX * scrollRateX + scrollRateY * scrollRateY)
        if rateMagnitude < scrollRateThreshold {
            let finalX = trunc(scrollRemainderX)
            let finalY = trunc(scrollRemainderY)
            if abs(finalX) >= 1 || abs(finalY) >= 1 { injectScrollPixels(Int32(finalX), Int32(finalY), context: context) }

            scrollRateX = 0
            scrollRateY = 0
            scrollTargetRateX = 0
            scrollTargetRateY = 0
            scrollRemainderX = 0
            scrollRemainderY = 0
            scrollContext = nil
            stopScrollOutputTimer()
        }
    }

    private func stopScrollOutputTimer() {
        scrollOutputTimer?.cancel()
        scrollOutputTimer = nil
        lastScrollOutputTime = 0
    }

    private func injectScrollPixels(
        _ pixelsX: Int32,
        _ pixelsY: Int32,
        context: (
            frame: CGRect,
            app: MirageApplication?,
            location: CGPoint?,
            modifiers: MirageModifierFlags,
            isPrecise: Bool
        )
    ) {
        let scrollPoint = if let normalizedLocation = context.location {
            CGPoint(
                x: context.frame.origin.x + normalizedLocation.x * context.frame.width,
                y: context.frame.origin.y + normalizedLocation.y * context.frame.height
            )
        } else {
            CGPoint(x: context.frame.midX, y: context.frame.midY)
        }

        guard let cgEvent = CGEvent(
            scrollWheelEvent2Source: nil,
            units: context.isPrecise ? .pixel : .line,
            wheelCount: 2,
            wheel1: pixelsY,
            wheel2: pixelsX,
            wheel3: 0
        ) else {
            return
        }

        cgEvent.location = scrollPoint
        postEvent(cgEvent)
    }
}

#endif
