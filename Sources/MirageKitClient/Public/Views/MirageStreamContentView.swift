//
//  MirageStreamContentView.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/23/26.
//

import SwiftUI
import MirageKit
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
    public let desktopStreamMode: MirageDesktopStreamMode
    public let onExitDesktopStream: (() -> Void)?
    public let onHardwareKeyboardPresenceChanged: ((Bool) -> Void)?
    public let onSoftwareKeyboardVisibilityChanged: ((Bool) -> Void)?
    public let dockSnapEnabled: Bool
    public let usesVirtualTrackpad: Bool
    public let softwareKeyboardVisible: Bool
    public let maxDrawableSize: CGSize?

    /// Resize holdoff task used during foreground transitions (iOS).
    @State private var resizeHoldoffTask: Task<Void, Never>?

    /// Whether resize events are currently allowed.
    @State private var allowsResizeEvents: Bool = true

    /// Whether the client is currently waiting for host to complete resize.
    @State private var isResizing: Bool = false
    @State private var resizeFallbackTask: Task<Void, Never>?
    @State private var displayResolutionTask: Task<Void, Never>?
    @State private var lastSentDisplayResolution: CGSize = .zero
    @State private var streamScaleTask: Task<Void, Never>?
    @State private var lastSentEncodedPixelSize: CGSize = .zero

    @State private var scrollInputSampler = ScrollInputSampler()
    @State private var pointerInputSampler = PointerInputSampler()

    /// Creates a streaming content view backed by a session store and client service.
    /// - Parameters:
    ///   - session: Session metadata describing the stream.
    ///   - sessionStore: Session store that tracks frames, focus, and resize updates.
    ///   - clientService: The client service used to send input and resize events.
    ///   - isDesktopStream: Whether the stream represents a desktop session.
    ///   - desktopStreamMode: Desktop stream mode (mirrored vs secondary display).
    ///   - onExitDesktopStream: Optional handler for the desktop exit shortcut.
    ///   - onHardwareKeyboardPresenceChanged: Optional handler for hardware keyboard availability.
    ///   - onSoftwareKeyboardVisibilityChanged: Optional handler for software keyboard visibility.
    ///   - dockSnapEnabled: Whether input should snap to the dock edge on iPadOS.
    ///   - usesVirtualTrackpad: Whether direct touch uses a draggable virtual cursor.
    ///   - softwareKeyboardVisible: Whether the software keyboard should be visible.
    public init(
        session: MirageStreamSessionState,
        sessionStore: MirageClientSessionStore,
        clientService: MirageClientService,
        isDesktopStream: Bool = false,
        desktopStreamMode: MirageDesktopStreamMode = .mirrored,
        onExitDesktopStream: (() -> Void)? = nil,
        onHardwareKeyboardPresenceChanged: ((Bool) -> Void)? = nil,
        onSoftwareKeyboardVisibilityChanged: ((Bool) -> Void)? = nil,
        dockSnapEnabled: Bool = false,
        usesVirtualTrackpad: Bool = false,
        softwareKeyboardVisible: Bool = false,
        maxDrawableSize: CGSize? = nil
    ) {
        self.session = session
        self.sessionStore = sessionStore
        self.clientService = clientService
        self.isDesktopStream = isDesktopStream
        self.desktopStreamMode = desktopStreamMode
        self.onExitDesktopStream = onExitDesktopStream
        self.onHardwareKeyboardPresenceChanged = onHardwareKeyboardPresenceChanged
        self.onSoftwareKeyboardVisibilityChanged = onSoftwareKeyboardVisibilityChanged
        self.dockSnapEnabled = dockSnapEnabled
        self.usesVirtualTrackpad = usesVirtualTrackpad
        self.softwareKeyboardVisible = softwareKeyboardVisible
        self.maxDrawableSize = maxDrawableSize
    }

    public var body: some View {
        Group {
            #if os(iOS) || os(visionOS)
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
                cursorPositionStore: clientService.cursorPositionStore,
                onBecomeActive: {
                    handleForegroundRecovery()
                },
                onHardwareKeyboardPresenceChanged: onHardwareKeyboardPresenceChanged,
                onSoftwareKeyboardVisibilityChanged: onSoftwareKeyboardVisibilityChanged,
                dockSnapEnabled: dockSnapEnabled,
                usesVirtualTrackpad: usesVirtualTrackpad,
                softwareKeyboardVisible: softwareKeyboardVisible,
                cursorLockEnabled: isDesktopStream && desktopStreamMode == .secondary,
                maxDrawableSize: maxDrawableSize
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
                },
                cursorStore: clientService.cursorStore,
                cursorPositionStore: clientService.cursorPositionStore,
                cursorLockEnabled: isDesktopStream && desktopStreamMode == .secondary,
                maxDrawableSize: maxDrawableSize
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
            if isResizing { isResizing = false }
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
            displayResolutionTask?.cancel()
            displayResolutionTask = nil
            streamScaleTask?.cancel()
            streamScaleTask = nil
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
        if case let .keyDown(keyEvent) = event,
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
        if case let .scrollWheel(scrollEvent) = event {
            scrollInputSampler.handle(scrollEvent) { resampledEvent in
                clientService.sendInputFireAndForget(.scrollWheel(resampledEvent), forStream: session.streamID)
            }
            return
        }

        switch event {
        case let .mouseMoved(mouseEvent):
            pointerInputSampler.handle(kind: .move, event: mouseEvent) { resampledEvent in
                clientService.sendInputFireAndForget(.mouseMoved(resampledEvent), forStream: session.streamID)
            }
            return
        case let .mouseDragged(mouseEvent):
            pointerInputSampler.handle(kind: .leftDrag, event: mouseEvent) { resampledEvent in
                clientService.sendInputFireAndForget(.mouseDragged(resampledEvent), forStream: session.streamID)
            }
            return
        case let .rightMouseDragged(mouseEvent):
            pointerInputSampler.handle(kind: .rightDrag, event: mouseEvent) { resampledEvent in
                clientService.sendInputFireAndForget(.rightMouseDragged(resampledEvent), forStream: session.streamID)
            }
            return
        case let .otherMouseDragged(mouseEvent):
            pointerInputSampler.handle(kind: .otherDrag, event: mouseEvent) { resampledEvent in
                clientService.sendInputFireAndForget(.otherMouseDragged(resampledEvent), forStream: session.streamID)
            }
            return
        case .mouseDown,
             .mouseUp,
             .otherMouseDown,
             .otherMouseUp,
             .rightMouseDown,
             .rightMouseUp:
            pointerInputSampler.reset()
        default:
            break
        }

        clientService.sendInputFireAndForget(event, forStream: session.streamID)
    }

    private func handleDrawableMetricsChanged(_ metrics: MirageDrawableMetrics) {
        guard metrics.pixelSize.width > 0, metrics.pixelSize.height > 0 else { return }

        let viewSize = metrics.viewSize
        let scaleFactor = metrics.scaleFactor
        let resolvedRawPixelSize = metrics.pixelSize

        #if os(iOS) || os(visionOS)
        if viewSize.width > 0, viewSize.height > 0 {
            MirageClientService.lastKnownViewSize = viewSize
        }
        if resolvedRawPixelSize.width > 0, resolvedRawPixelSize.height > 0 {
            MirageClientService.lastKnownDrawablePixelSize = resolvedRawPixelSize
        }
        let fallbackScreenSize = viewSize
        #else
        let screenBounds = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let fallbackScreenSize = screenBounds.size
        #endif

        let effectiveScreenSize = (viewSize == .zero) ? fallbackScreenSize : viewSize

        Task { @MainActor [clientService] in
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
                    if isResizing { isResizing = false }
                }
            }

            if !isDesktopStream {
                guard let controller = clientService.controller(for: session.streamID) else { return }
                await controller.handleDrawableSizeChanged(
                    resolvedRawPixelSize,
                    screenBounds: effectiveScreenSize,
                    scaleFactor: scaleFactor
                )
            }

            scheduleStreamScaleUpdate(for: viewSize)

            guard isDesktopStream else { return }

            let preferredDisplaySize = viewSize

            displayResolutionTask?.cancel()
            displayResolutionTask = Task { @MainActor in
                do {
                    try await Task.sleep(for: .milliseconds(200))
                } catch {
                    return
                }

                guard lastSentDisplayResolution != preferredDisplaySize else { return }
                lastSentDisplayResolution = preferredDisplaySize
                try? await clientService.sendDisplayResolutionChange(
                    streamID: session.streamID,
                    newResolution: preferredDisplaySize
                )
            }
        }
    }

    private func scheduleStreamScaleUpdate(for viewSize: CGSize) {
        guard let maxDrawableSize,
              maxDrawableSize.width > 0,
              maxDrawableSize.height > 0,
              viewSize.width > 0,
              viewSize.height > 0 else {
            return
        }

        let basePoints = clientService.scaledDisplayResolution(viewSize)
        guard basePoints.width > 0, basePoints.height > 0 else { return }

        let virtualDisplayScaleFactor: CGFloat = 2.0
        let basePixels = CGSize(
            width: basePoints.width * virtualDisplayScaleFactor,
            height: basePoints.height * virtualDisplayScaleFactor
        )
        let widthScale = maxDrawableSize.width / basePixels.width
        let heightScale = maxDrawableSize.height / basePixels.height
        let clampedScale = clientService.clampStreamScale(min(1.0, widthScale, heightScale))

        let rawTargetSize = CGSize(
            width: basePixels.width * clampedScale,
            height: basePixels.height * clampedScale
        )
        let alignedTargetSize = CGSize(
            width: min(maxDrawableSize.width, alignedEven(rawTargetSize.width)),
            height: min(maxDrawableSize.height, alignedEven(rawTargetSize.height))
        )

        guard alignedTargetSize != lastSentEncodedPixelSize else { return }

        streamScaleTask?.cancel()
        let targetScale = clampedScale
        let targetSize = alignedTargetSize
        streamScaleTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(200))
            } catch {
                return
            }

            guard targetSize != lastSentEncodedPixelSize else { return }
            lastSentEncodedPixelSize = targetSize
            try? await clientService.sendStreamScaleChange(
                streamID: session.streamID,
                scale: targetScale
            )
        }
    }

    private func alignedEven(_ value: CGFloat) -> CGFloat {
        let rounded = CGFloat(Int(value.rounded()))
        let even = rounded - CGFloat(Int(rounded) % 2)
        return max(2, even)
    }

    #if os(iOS) || os(visionOS)
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
        if isResizing { isResizing = false }

        scheduleResizeHoldoff()
        clientService.requestStreamRecovery(for: session.streamID)
    }
    #endif
}

@MainActor
private final class ScrollInputSampler {
    private let outputInterval: TimeInterval = 1.0 / 120.0
    private let decayDelay: TimeInterval = 0.03
    private let decayFactor: CGFloat = 0.85
    private let rateThreshold: CGFloat = 2.0

    private var scrollRateX: CGFloat = 0
    private var scrollRateY: CGFloat = 0
    private var lastScrollTime: TimeInterval = 0
    private var lastLocation: CGPoint?
    private var lastModifiers: MirageModifierFlags = []
    private var lastIsPrecise: Bool = true
    private var lastMomentumPhase: MirageScrollPhase = .none
    private var scrollTimer: DispatchSourceTimer?

    func handle(_ event: MirageScrollEvent, send: @escaping (MirageScrollEvent) -> Void) {
        lastLocation = event.location
        lastModifiers = event.modifiers
        lastIsPrecise = event.isPrecise
        if event.momentumPhase != .none { lastMomentumPhase = event.momentumPhase }

        if event.phase == .began || event.momentumPhase == .began {
            resetRate()
            send(phaseEvent(from: event))
        }

        if event.deltaX != 0 || event.deltaY != 0 { applyDelta(event, send: send) }

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
    }

    private func applyDelta(_ event: MirageScrollEvent, send: @escaping (MirageScrollEvent) -> Void) {
        let now = CACurrentMediaTime()
        let dt = max(0.004, min(now - lastScrollTime, 0.1))
        lastScrollTime = now

        scrollRateX = event.deltaX / CGFloat(dt)
        scrollRateY = event.deltaY / CGFloat(dt)

        if scrollTimer == nil { startTimer(send: send) }
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

    private let outputInterval: TimeInterval = 1.0 / 120.0
    private let idleTimeout: TimeInterval = 0.05

    private var lastEvent: MirageMouseEvent?
    private var lastKind: Kind = .move
    private var lastInputTime: TimeInterval = 0
    private var timer: DispatchSourceTimer?

    func handle(kind: Kind, event: MirageMouseEvent, send: @escaping (MirageMouseEvent) -> Void) {
        lastEvent = event
        lastKind = kind
        lastInputTime = CACurrentMediaTime()

        send(event)

        if timer == nil { startTimer(send: send) }
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
}
