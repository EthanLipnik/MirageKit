//
//  MirageStreamContentView.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/23/26.
//

import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Streaming content view that handles input, resizing, and focus.
///
/// This view bridges `MirageStreamViewRepresentable` with a `MirageClientSessionStore`
/// to coordinate focus, resize events, and input forwarding.
public struct MirageStreamContentView: View {
    public let session: MirageStreamSessionState
    public let sessionStore: MirageClientSessionStore
    public let clientService: MirageClientService
    public let isDesktopStream: Bool
    public let onExitDesktopStream: (() -> Void)?
    public let dockSnapEnabled: Bool

    /// Resize holdoff task used during foreground transitions (iOS).
    @State private var resizeHoldoffTask: Task<Void, Never>?

    /// Whether resize events are currently allowed.
    @State private var allowsResizeEvents: Bool = true

    /// Whether the client is currently waiting for host to complete resize.
    @State private var isResizing: Bool = false
    @State private var resizeFallbackTask: Task<Void, Never>?

    @State private var scrollInputSampler = ScrollInputSampler()
    @State private var pointerInputSampler = PointerInputSampler()

    /// Creates a streaming content view backed by a session store and client service.
    /// - Parameters:
    ///   - session: Session metadata describing the stream.
    ///   - sessionStore: Session store that tracks frames, focus, and resize updates.
    ///   - clientService: The client service used to send input and resize events.
    ///   - isDesktopStream: Whether the stream represents a desktop session.
    ///   - onExitDesktopStream: Optional handler for the desktop exit shortcut.
    ///   - dockSnapEnabled: Whether input should snap to the dock edge on iPadOS.
    public init(
        session: MirageStreamSessionState,
        sessionStore: MirageClientSessionStore,
        clientService: MirageClientService,
        isDesktopStream: Bool = false,
        onExitDesktopStream: (() -> Void)? = nil,
        dockSnapEnabled: Bool = false
    ) {
        self.session = session
        self.sessionStore = sessionStore
        self.clientService = clientService
        self.isDesktopStream = isDesktopStream
        self.onExitDesktopStream = onExitDesktopStream
        self.dockSnapEnabled = dockSnapEnabled
    }

    public var body: some View {
        Group {
#if os(iOS)
            MirageStreamViewRepresentable(
                streamID: session.streamID,
                onInputEvent: { event in
                    sendInputEvent(event)
                },
                onDrawableMetricsChanged: { metrics in
                    handleDrawableMetricsChanged(metrics)
                },
                onRefreshRateOverrideChange: { override in
                    clientService.updateStreamRefreshRateOverride(
                        streamID: session.streamID,
                        maxRefreshRate: override
                    )
                },
                cursorStore: clientService.cursorStore,
                onBecomeActive: {
                    handleForegroundRecovery()
                },
                dockSnapEnabled: dockSnapEnabled
            )
            .ignoresSafeArea()
            .blur(radius: isResizing ? 20 : 0)
            .animation(.easeInOut(duration: 0.15), value: isResizing)
#else
            MirageStreamViewRepresentable(
                streamID: session.streamID,
                onInputEvent: { event in
                    sendInputEvent(event)
                },
                onDrawableMetricsChanged: { metrics in
                    handleDrawableMetricsChanged(metrics)
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .blur(radius: isResizing ? 20 : 0)
            .animation(.easeInOut(duration: 0.15), value: isResizing)
#endif
        }
        .overlay {
            if !session.hasReceivedFirstFrame {
                Rectangle()
                    .fill(.black)
                    .overlay {
                        VStack(spacing: 16) {
                            ProgressView()
                                .controlSize(.large)
                                .tint(.white)

                            Text("Connecting to stream...")
                                .foregroundStyle(.white.opacity(0.7))
                        }
                    }
                    .allowsHitTesting(false)
            }
        }
        .onChange(of: sessionStore.sessionMinSizes[session.id]) { _, _ in
            if isResizing {
                isResizing = false
            }
        }
        .onAppear {
            sessionStore.setFocusedSession(session.id)
            clientService.sendInputFireAndForget(.windowFocus, forStream: session.streamID)
        }
        .onDisappear {
            scrollInputSampler.reset()
            pointerInputSampler.reset()
            resizeFallbackTask?.cancel()
            resizeFallbackTask = nil
        }
        #if os(macOS)
        .background(
            MirageWindowFocusObserver(
                sessionID: session.id,
                streamID: session.streamID,
                sessionStore: sessionStore,
                clientService: clientService
            )
        )
        #endif
    }

    private func sendInputEvent(_ event: MirageInputEvent) {
        if case .keyDown(let keyEvent) = event,
           keyEvent.keyCode == 0x35,
           keyEvent.modifiers.contains(.control),
           keyEvent.modifiers.contains(.option),
           !keyEvent.modifiers.contains(.command),
           isDesktopStream {
            onExitDesktopStream?()
            return
        }

#if os(macOS)
        guard sessionStore.focusedSessionID == session.id else { return }
#else
        if sessionStore.focusedSessionID != session.id {
            sessionStore.setFocusedSession(session.id)
            clientService.sendInputFireAndForget(.windowFocus, forStream: session.streamID)
        }
#endif
        if case .scrollWheel(let scrollEvent) = event {
            let targetFrameRate = resolvedStreamTargetFrameRate()
            scrollInputSampler.handle(scrollEvent, targetFrameRate: targetFrameRate) { resampledEvent in
                clientService.sendInputFireAndForget(.scrollWheel(resampledEvent), forStream: session.streamID)
            }
            return
        }

        switch event {
        case .mouseMoved(let mouseEvent):
            let targetFrameRate = resolvedStreamTargetFrameRate()
            pointerInputSampler.handle(kind: .move, event: mouseEvent, targetFrameRate: targetFrameRate) { resampledEvent in
                clientService.sendInputFireAndForget(.mouseMoved(resampledEvent), forStream: session.streamID)
            }
            return
        case .mouseDragged(let mouseEvent):
            let targetFrameRate = resolvedStreamTargetFrameRate()
            pointerInputSampler.handle(kind: .leftDrag, event: mouseEvent, targetFrameRate: targetFrameRate) { resampledEvent in
                clientService.sendInputFireAndForget(.mouseDragged(resampledEvent), forStream: session.streamID)
            }
            return
        case .rightMouseDragged(let mouseEvent):
            let targetFrameRate = resolvedStreamTargetFrameRate()
            pointerInputSampler.handle(kind: .rightDrag, event: mouseEvent, targetFrameRate: targetFrameRate) { resampledEvent in
                clientService.sendInputFireAndForget(.rightMouseDragged(resampledEvent), forStream: session.streamID)
            }
            return
        case .otherMouseDragged(let mouseEvent):
            let targetFrameRate = resolvedStreamTargetFrameRate()
            pointerInputSampler.handle(kind: .otherDrag, event: mouseEvent, targetFrameRate: targetFrameRate) { resampledEvent in
                clientService.sendInputFireAndForget(.otherMouseDragged(resampledEvent), forStream: session.streamID)
            }
            return
        case .mouseDown, .mouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp:
            pointerInputSampler.reset()
        default:
            break
        }

        clientService.sendInputFireAndForget(event, forStream: session.streamID)
    }

    private func resolvedStreamTargetFrameRate() -> Int {
        let snapshot = clientService.metricsStore.snapshot(for: session.streamID)
        let hostTarget = snapshot?.hostTargetFrameRate ?? 0
        let fallbackTarget = 60
        let resolved = hostTarget > 0 ? hostTarget : fallbackTarget
        return MirageInputSampling.clampedTargetFrameRate(resolved)
    }

    private func handleDrawableMetricsChanged(_ metrics: MirageDrawableMetrics) {
        guard metrics.pixelSize.width > 0, metrics.pixelSize.height > 0 else { return }
        guard allowsResizeEvents else { return }

        if session.hasReceivedFirstFrame {
            isResizing = true
            resizeFallbackTask?.cancel()
            resizeFallbackTask = Task { @MainActor in
                do {
                    try await Task.sleep(for: .seconds(2))
                } catch {
                    return
                }
                if isResizing {
                    isResizing = false
                }
            }
        }

        #if os(iOS)
        MirageClientService.lastKnownDrawableSize = metrics.pixelSize
        let fallbackScreenSize = CGSize(width: 1920, height: 1080)
        #else
        let screenBounds = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let fallbackScreenSize = screenBounds.size
        #endif

        let viewSize = metrics.viewSize
        let scaleFactor = metrics.scaleFactor

        let effectiveScreenSize = (viewSize == .zero) ? fallbackScreenSize : viewSize

        Task { @MainActor [clientService] in
            guard let controller = clientService.controller(for: session.streamID) else { return }
            await controller.handleDrawableSizeChanged(
                metrics.pixelSize,
                screenBounds: effectiveScreenSize,
                scaleFactor: scaleFactor
            )
        }
    }

#if os(iOS)
    private func scheduleResizeHoldoff() {
        resizeHoldoffTask?.cancel()
        allowsResizeEvents = false
        resizeHoldoffTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(600))
            } catch {
                return
            }
            allowsResizeEvents = true
        }
    }

    private func handleForegroundRecovery() {
        if isResizing {
            isResizing = false
        }

        scheduleResizeHoldoff()
        clientService.requestStreamRecovery(for: session.streamID)
    }
#endif
}

enum MirageInputSampling {
    static let minimumFrameRate = 30
    static let maximumFrameRate = 120

    static func clampedTargetFrameRate(_ targetFrameRate: Int) -> Int {
        min(maximumFrameRate, max(minimumFrameRate, targetFrameRate))
    }

    static func outputInterval(for targetFrameRate: Int) -> TimeInterval {
        1.0 / TimeInterval(clampedTargetFrameRate(targetFrameRate))
    }

    static func synthesisThreshold(
        outputInterval: TimeInterval,
        lastRawDeltaInterval: TimeInterval,
        multiplier: TimeInterval
    ) -> TimeInterval {
        let cadenceInterval = max(outputInterval, lastRawDeltaInterval)
        return cadenceInterval * multiplier
    }
}

@MainActor
private final class ScrollInputSampler {
    private var outputInterval: TimeInterval = 1.0 / 60.0
    private let decayDelay: TimeInterval = 0.03
    private let decayFactor: CGFloat = 0.85
    private let rateThreshold: CGFloat = 2.0
    private let synthDelayMultiplier: TimeInterval = 1.5

    private var scrollRateX: CGFloat = 0
    private var scrollRateY: CGFloat = 0
    private var lastScrollTime: TimeInterval = 0
    private var lastLocation: CGPoint?
    private var lastModifiers: MirageModifierFlags = []
    private var lastIsPrecise: Bool = true
    private var lastMomentumPhase: MirageScrollPhase = .none
    private var scrollTimer: DispatchSourceTimer?
    private var lastRawSendTime: TimeInterval = 0
    private var lastRawDeltaInterval: TimeInterval = 0

    func handle(
        _ event: MirageScrollEvent,
        targetFrameRate: Int,
        send: @escaping (MirageScrollEvent) -> Void
    ) {
        updateTargetFrameRate(targetFrameRate, send: send)
        lastLocation = event.location
        lastModifiers = event.modifiers
        lastIsPrecise = event.isPrecise
        if event.momentumPhase != .none {
            lastMomentumPhase = event.momentumPhase
        }

        if event.phase == .began || event.momentumPhase == .began {
            resetRate()
            send(phaseEvent(from: event))
        }

        if event.deltaX != 0 || event.deltaY != 0 {
            // Send raw deltas immediately to avoid losing small horizontal deltas.
            let rawSendTime = CACurrentMediaTime()
            send(event)
            recordRawSendTime(rawSendTime)
            applyDelta(event, send: send)
        }

        if event.phase == .ended || event.phase == .cancelled ||
            event.momentumPhase == .ended || event.momentumPhase == .cancelled {
            send(phaseEvent(from: event))
        }
    }

    func reset() {
        scrollTimer?.cancel()
        scrollTimer = nil
        resetRate()
        lastMomentumPhase = .none
        lastRawDeltaInterval = 0
        lastRawSendTime = 0
    }

    private func applyDelta(_ event: MirageScrollEvent, send: @escaping (MirageScrollEvent) -> Void) {
        let now = CACurrentMediaTime()
        let dt = max(0.004, min(now - lastScrollTime, 0.1))
        lastScrollTime = now

        scrollRateX = event.deltaX / CGFloat(dt)
        scrollRateY = event.deltaY / CGFloat(dt)

        if scrollTimer == nil {
            startTimer(send: send)
        }
    }

    private func startTimer(send: @escaping (MirageScrollEvent) -> Void) {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(
            deadline: .now() + outputInterval,
            repeating: outputInterval,
            leeway: .milliseconds(1)
        )
        timer.setEventHandler { [weak self] in
            self?.tick(send: send)
        }
        timer.resume()
        scrollTimer = timer
    }

    private func tick(send: @escaping (MirageScrollEvent) -> Void) {
        let now = CACurrentMediaTime()
        let timeSinceInput = now - lastScrollTime
        let timeSinceRawSend = now - lastRawSendTime

        // Only synthesize deltas when input cadence drops below the most recent raw cadence.
        let synthesisThreshold = MirageInputSampling.synthesisThreshold(
            outputInterval: outputInterval,
            lastRawDeltaInterval: lastRawDeltaInterval,
            multiplier: synthDelayMultiplier
        )
        guard lastRawSendTime > 0, timeSinceRawSend > synthesisThreshold else { return }

        if timeSinceInput > decayDelay {
            scrollRateX *= decayFactor
            scrollRateY *= decayFactor
        }

        let deltaX = scrollRateX * CGFloat(outputInterval)
        let deltaY = scrollRateY * CGFloat(outputInterval)

        if deltaX != 0 || deltaY != 0 {
            let event = MirageScrollEvent(
                deltaX: deltaX,
                deltaY: deltaY,
                location: lastLocation,
                phase: .changed,
                momentumPhase: lastMomentumPhase == .changed ? .changed : .none,
                modifiers: lastModifiers,
                isPrecise: lastIsPrecise
            )
            send(event)
        }

        let rateMagnitude = sqrt(scrollRateX * scrollRateX + scrollRateY * scrollRateY)
        if rateMagnitude < rateThreshold {
            scrollTimer?.cancel()
            scrollTimer = nil
            resetRate()
        }
    }

    private func resetRate() {
        scrollRateX = 0
        scrollRateY = 0
        lastScrollTime = CACurrentMediaTime()
    }

    private func updateTargetFrameRate(_ targetFrameRate: Int, send: @escaping (MirageScrollEvent) -> Void) {
        let clampedTarget = MirageInputSampling.clampedTargetFrameRate(targetFrameRate)
        let newOutputInterval = MirageInputSampling.outputInterval(for: clampedTarget)
        guard abs(newOutputInterval - outputInterval) > 0.000_5 else { return }
        outputInterval = newOutputInterval
        if scrollTimer != nil {
            scrollTimer?.cancel()
            scrollTimer = nil
            startTimer(send: send)
        }
    }

    private func recordRawSendTime(_ now: TimeInterval) {
        if lastRawSendTime > 0 {
            let dt = max(0.004, min(now - lastRawSendTime, 0.2))
            lastRawDeltaInterval = dt
        } else {
            lastRawDeltaInterval = outputInterval
        }
        lastRawSendTime = now
    }

    private func phaseEvent(from event: MirageScrollEvent) -> MirageScrollEvent {
        MirageScrollEvent(
            deltaX: 0,
            deltaY: 0,
            location: event.location,
            phase: event.phase,
            momentumPhase: event.momentumPhase,
            modifiers: event.modifiers,
            isPrecise: event.isPrecise
        )
    }
}

@MainActor
private final class PointerInputSampler {
    enum Kind {
        case move
        case leftDrag
        case rightDrag
        case otherDrag
    }

    private var outputInterval: TimeInterval = 1.0 / 60.0
    private let idleTimeout: TimeInterval = 0.05

    private var lastEvent: MirageMouseEvent?
    private var lastKind: Kind = .move
    private var lastInputTime: TimeInterval = 0
    private var timer: DispatchSourceTimer?

    func handle(
        kind: Kind,
        event: MirageMouseEvent,
        targetFrameRate: Int,
        send: @escaping (MirageMouseEvent) -> Void
    ) {
        updateTargetFrameRate(targetFrameRate, send: send)
        lastEvent = event
        lastKind = kind
        lastInputTime = CACurrentMediaTime()

        send(event)

        if timer == nil {
            startTimer(send: send)
        }
    }

    func reset() {
        timer?.cancel()
        timer = nil
        lastEvent = nil
    }

    private func startTimer(send: @escaping (MirageMouseEvent) -> Void) {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(
            deadline: .now() + outputInterval,
            repeating: outputInterval,
            leeway: .milliseconds(1)
        )
        timer.setEventHandler { [weak self] in
            self?.tick(send: send)
        }
        timer.resume()
        self.timer = timer
    }

    private func tick(send: @escaping (MirageMouseEvent) -> Void) {
        guard let event = lastEvent else {
            reset()
            return
        }

        let now = CACurrentMediaTime()
        if now - lastInputTime > idleTimeout {
            reset()
            return
        }

        send(event)
    }

    private func updateTargetFrameRate(_ targetFrameRate: Int, send: @escaping (MirageMouseEvent) -> Void) {
        let clampedTarget = MirageInputSampling.clampedTargetFrameRate(targetFrameRate)
        let newOutputInterval = MirageInputSampling.outputInterval(for: clampedTarget)
        guard abs(newOutputInterval - outputInterval) > 0.000_5 else { return }
        outputInterval = newOutputInterval
        if timer != nil {
            timer?.cancel()
            timer = nil
            startTimer(send: send)
        }
    }
}
