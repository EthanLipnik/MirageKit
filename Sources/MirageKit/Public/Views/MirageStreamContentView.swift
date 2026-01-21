//
//  MirageStreamContentView.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/16/26.
//

import SwiftUI
import CoreVideo
import QuartzCore
#if os(macOS)
import AppKit
#endif

/// Streaming content view that handles input, resizing, and focus.
///
/// This view bridges `MirageStreamViewRepresentable` with a `MirageClientSessionStore`
/// to coordinate focus, resize events, and input forwarding.
public struct MirageStreamContentView: View {
    #if os(iOS)
    @Environment(\.currentScreen) private var currentScreen
    #endif

    public let session: MirageStreamSessionState
    public let sessionStore: MirageClientSessionStore
    public let clientService: MirageClientService
    public let isDesktopStream: Bool
    public let onExitDesktopStream: (() -> Void)?
    public let dockSnapEnabled: Bool

    /// Content rectangle for current frame (for SCK black bar cropping).
    @State private var contentRect: CGRect = .zero

    /// Last relative sizing sent to host - prevents duplicate resize events.
    @State private var lastSentAspectRatio: CGFloat = 0
    @State private var lastSentRelativeScale: CGFloat = 0
    @State private var lastSentPixelSize: CGSize = .zero

    /// Debounce task for resize events - only sends after user stops resizing.
    @State private var resizeDebounceTask: Task<Void, Never>?

    /// Resize holdoff task used during foreground transitions (iOS).
    @State private var resizeHoldoffTask: Task<Void, Never>?

    /// Whether resize events are currently allowed.
    @State private var allowsResizeEvents: Bool = true

    /// Whether the client is currently waiting for host to complete resize.
    @State private var isResizing: Bool = false

    /// Whether we've received at least one frame (prevents resize blocking on initial load).
    @State private var hasReceivedFirstFrame: Bool = false

    /// The frame to display - frozen during resize, updated right before unblur.
    @State private var displayedFrame: CVPixelBuffer?

    /// Content rect for the displayed frame (frozen during resize).
    @State private var displayedContentRect: CGRect = .zero
    @State private var scrollInputSampler = ScrollInputSampler()
    @State private var pointerInputSampler = PointerInputSampler()

    #if os(iOS)
    /// Captured screen info for async operations (environment values can't be accessed in Tasks).
    @State private var capturedScreenBounds: CGRect = .zero
    @State private var capturedScreenScale: CGFloat = 2.0
    #endif

    /// Maximum resolution cap to prevent GPU overload (5K).
    private static let maxResolutionWidth: CGFloat = 5120
    private static let maxResolutionHeight: CGFloat = 2880

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
                latestFrame: $displayedFrame,
                contentRect: displayedContentRect,
                onInputEvent: { event in
                    sendInputEvent(event)
                },
                onDrawableSizeChanged: { pixelSize in
                    handleDrawableSizeChanged(pixelSize)
                },
                cursorType: sessionStore.cursorTypes[session.streamID] ?? .arrow,
                cursorVisible: sessionStore.cursorVisibility[session.streamID] ?? true,
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
                latestFrame: $displayedFrame,
                contentRect: displayedContentRect,
                onInputEvent: { event in
                    sendInputEvent(event)
                },
                onDrawableSizeChanged: { pixelSize in
                    handleDrawableSizeChanged(pixelSize)
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .blur(radius: isResizing ? 20 : 0)
            .animation(.easeInOut(duration: 0.15), value: isResizing)
#endif
        }
        .overlay {
            if displayedFrame == nil {
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
        .onChange(of: sessionStore.latestFrames[session.id]) { _, newFrame in
            let latestContentRect = sessionStore.contentRects[session.id] ?? .zero
            contentRect = latestContentRect

            if !hasReceivedFirstFrame && newFrame != nil {
                hasReceivedFirstFrame = true
            }

            guard !isResizing else { return }
            displayedFrame = newFrame
            displayedContentRect = latestContentRect
        }
        .onChange(of: sessionStore.sessionMinSizes[session.id]) { _, _ in
            if isResizing {
                displayedFrame = sessionStore.latestFrames[session.id]
                displayedContentRect = contentRect
                isResizing = false
            }
        }
        .onAppear {
            displayedFrame = sessionStore.latestFrames[session.id]
            displayedContentRect = sessionStore.contentRects[session.id] ?? .zero

            sessionStore.setFocusedSession(session.id)
            clientService.sendInputFireAndForget(.windowFocus, forStream: session.streamID)
        }
        .onDisappear {
            scrollInputSampler.reset()
            pointerInputSampler.reset()
        }
        #if os(iOS)
        .readScreen { screen in
            Task { @MainActor in
                capturedScreenBounds = screen.bounds
                capturedScreenScale = screen.nativeScale
            }
        }
        #endif
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
            scrollInputSampler.handle(scrollEvent) { resampledEvent in
                clientService.sendInputFireAndForget(.scrollWheel(resampledEvent), forStream: session.streamID)
            }
            return
        }

        switch event {
        case .mouseMoved(let mouseEvent):
            pointerInputSampler.handle(kind: .move, event: mouseEvent) { resampledEvent in
                clientService.sendInputFireAndForget(.mouseMoved(resampledEvent), forStream: session.streamID)
            }
            return
        case .mouseDragged(let mouseEvent):
            pointerInputSampler.handle(kind: .leftDrag, event: mouseEvent) { resampledEvent in
                clientService.sendInputFireAndForget(.mouseDragged(resampledEvent), forStream: session.streamID)
            }
            return
        case .rightMouseDragged(let mouseEvent):
            pointerInputSampler.handle(kind: .rightDrag, event: mouseEvent) { resampledEvent in
                clientService.sendInputFireAndForget(.rightMouseDragged(resampledEvent), forStream: session.streamID)
            }
            return
        case .otherMouseDragged(let mouseEvent):
            pointerInputSampler.handle(kind: .otherDrag, event: mouseEvent) { resampledEvent in
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

    private func handleDrawableSizeChanged(_ pixelSize: CGSize) {
        guard pixelSize.width > 0, pixelSize.height > 0 else { return }
        guard allowsResizeEvents else { return }

        if hasReceivedFirstFrame {
            isResizing = true
        }

#if os(iOS)
        MirageClientService.lastKnownDrawableSize = pixelSize

        let screenBounds = currentScreen?.bounds
            ?? (!capturedScreenBounds.isEmpty ? capturedScreenBounds : CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let scaleFactor: CGFloat
        if let currentScale = currentScreen?.nativeScale, currentScale > 0 {
            scaleFactor = currentScale
        } else if capturedScreenScale > 0 {
            scaleFactor = capturedScreenScale
        } else {
            scaleFactor = 2.0
        }
#else
        let screenBounds = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let scaleFactor = NSScreen.main?.backingScaleFactor ?? 2.0
#endif

        resizeDebounceTask?.cancel()

        resizeDebounceTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(200))
            } catch {
                return
            }

            guard allowsResizeEvents else { return }

            let aspectRatio = pixelSize.width / pixelSize.height

            var cappedSize = pixelSize
            if cappedSize.width > Self.maxResolutionWidth {
                cappedSize.width = Self.maxResolutionWidth
                cappedSize.height = cappedSize.width / aspectRatio
            }
            if cappedSize.height > Self.maxResolutionHeight {
                cappedSize.height = Self.maxResolutionHeight
                cappedSize.width = cappedSize.height * aspectRatio
            }

            cappedSize.width = floor(cappedSize.width / 2) * 2
            cappedSize.height = floor(cappedSize.height / 2) * 2
            let cappedPixelSize = CGSize(width: cappedSize.width, height: cappedSize.height)

            let drawablePointSize = CGSize(
                width: cappedSize.width / scaleFactor,
                height: cappedSize.height / scaleFactor
            )
            let drawableArea = drawablePointSize.width * drawablePointSize.height
            let screenArea = screenBounds.width * screenBounds.height
            let relativeScale = min(1.0, drawableArea / screenArea)

            let isInitialLayout = lastSentAspectRatio == 0 && lastSentRelativeScale == 0 && lastSentPixelSize == .zero
            if isInitialLayout {
                lastSentAspectRatio = aspectRatio
                lastSentRelativeScale = relativeScale
                lastSentPixelSize = cappedPixelSize
                return
            }

            let aspectChanged = abs(aspectRatio - lastSentAspectRatio) > 0.01
            let scaleChanged = abs(relativeScale - lastSentRelativeScale) > 0.01
            let pixelChanged = cappedPixelSize != lastSentPixelSize
            guard aspectChanged || scaleChanged || pixelChanged else { return }

            lastSentAspectRatio = aspectRatio
            lastSentRelativeScale = relativeScale
            lastSentPixelSize = cappedPixelSize

            let event = MirageRelativeResizeEvent(
                windowID: session.window.id,
                aspectRatio: aspectRatio,
                relativeScale: relativeScale,
                clientScreenSize: screenBounds.size,
                pixelWidth: Int(cappedSize.width),
                pixelHeight: Int(cappedSize.height)
            )
            do {
                try await clientService.sendInput(.relativeResize(event), forStream: session.streamID)
            } catch {
                MirageLogger.error(.client, "Failed to send relative resize event: \(error)")
            }

            try? await Task.sleep(for: .seconds(2))
            if isResizing {
                displayedFrame = sessionStore.latestFrames[session.id]
                displayedContentRect = contentRect
                isResizing = false
            }
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
            displayedFrame = sessionStore.latestFrames[session.id]
            displayedContentRect = contentRect
            isResizing = false
        }

        resizeDebounceTask?.cancel()
        resizeDebounceTask = nil

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
        if event.momentumPhase != .none {
            lastMomentumPhase = event.momentumPhase
        }

        if event.phase == .began || event.momentumPhase == .began {
            resetRate()
            send(phaseEvent(from: event))
        }

        if event.deltaX != 0 || event.deltaY != 0 {
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
}
