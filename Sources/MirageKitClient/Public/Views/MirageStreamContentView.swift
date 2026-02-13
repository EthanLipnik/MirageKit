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
    public let onToggleDictationShortcut: (() -> Void)?
    public let desktopExitShortcut: MirageClientShortcut
    public let dictationShortcut: MirageClientShortcut
    public let onInputActivity: ((MirageInputEvent) -> Void)?
    public let onDirectTouchActivity: (() -> Void)?
    public let onHardwareKeyboardPresenceChanged: ((Bool) -> Void)?
    public let onSoftwareKeyboardVisibilityChanged: ((Bool) -> Void)?
    public let dockSnapEnabled: Bool
    public let directTouchInputMode: MirageDirectTouchInputMode
    public let softwareKeyboardVisible: Bool
    public let pencilInputMode: MiragePencilInputMode
    public let dictationToggleRequestID: UInt64
    public let onDictationStateChanged: ((Bool) -> Void)?
    public let onDictationError: ((String) -> Void)?
    public let dictationMode: MirageDictationMode
    public let maxDrawableSize: CGSize?
    private let desktopResizeAckTimeout: Duration = .seconds(3)
    private let desktopResizeConvergenceTolerance: CGFloat = 4

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
    @State private var awaitingDesktopResizeAck: Bool = false
    @State private var latestDrawableDisplaySize: CGSize = .zero
    @State private var sentDesktopPostAckCorrection: Bool = false
    @State private var desktopResizeAckTimeoutTask: Task<Void, Never>?

    @State private var scrollInputSampler = ScrollInputSampler()
    @State private var pointerInputSampler = PointerInputSampler()

    @available(*, deprecated, message: "Use directTouchInputMode instead.")
    public var usesVirtualTrackpad: Bool { directTouchInputMode == .dragCursor }

    /// Creates a streaming content view backed by a session store and client service.
    /// - Parameters:
    ///   - session: Session metadata describing the stream.
    ///   - sessionStore: Session store that tracks frames, focus, and resize updates.
    ///   - clientService: The client service used to send input and resize events.
    ///   - isDesktopStream: Whether the stream represents a desktop session.
    ///   - desktopStreamMode: Desktop stream mode (mirrored vs secondary display).
    ///   - onExitDesktopStream: Optional handler for the desktop exit shortcut.
    ///   - onToggleDictationShortcut: Optional handler for the dictation toggle shortcut.
    ///   - desktopExitShortcut: Client shortcut used for desktop stream exit.
    ///   - dictationShortcut: Client shortcut used for dictation toggle.
    ///   - onInputActivity: Optional callback invoked for each locally captured input event.
    ///   - onDirectTouchActivity: Optional callback invoked when direct finger touch input occurs.
    ///   - onHardwareKeyboardPresenceChanged: Optional handler for hardware keyboard availability.
    ///   - onSoftwareKeyboardVisibilityChanged: Optional handler for software keyboard visibility.
    ///   - dockSnapEnabled: Whether input should snap to the dock edge on iPadOS.
    ///   - usesVirtualTrackpad: Legacy direct-touch behavior flag.
    ///   - directTouchInputMode: Direct-touch behavior mode for iPad and visionOS clients.
    ///   - softwareKeyboardVisible: Whether the software keyboard should be visible.
    ///   - pencilInputMode: Apple Pencil behavior mode for iPad clients.
    ///   - dictationToggleRequestID: Increments to request a dictation toggle on iOS/visionOS.
    ///   - onDictationStateChanged: Optional callback for dictation start/stop state.
    ///   - onDictationError: Optional callback for user-facing dictation errors.
    ///   - dictationMode: Dictation behavior for realtime versus finalized output.
    public init(
        session: MirageStreamSessionState,
        sessionStore: MirageClientSessionStore,
        clientService: MirageClientService,
        isDesktopStream: Bool = false,
        desktopStreamMode: MirageDesktopStreamMode = .mirrored,
        onExitDesktopStream: (() -> Void)? = nil,
        onToggleDictationShortcut: (() -> Void)? = nil,
        desktopExitShortcut: MirageClientShortcut = .defaultDesktopExit,
        dictationShortcut: MirageClientShortcut = .defaultDictationToggle,
        onInputActivity: ((MirageInputEvent) -> Void)? = nil,
        onDirectTouchActivity: (() -> Void)? = nil,
        onHardwareKeyboardPresenceChanged: ((Bool) -> Void)? = nil,
        onSoftwareKeyboardVisibilityChanged: ((Bool) -> Void)? = nil,
        dockSnapEnabled: Bool = false,
        usesVirtualTrackpad: Bool = false,
        directTouchInputMode: MirageDirectTouchInputMode? = nil,
        softwareKeyboardVisible: Bool = false,
        pencilInputMode: MiragePencilInputMode = .drawingTablet,
        dictationToggleRequestID: UInt64 = 0,
        onDictationStateChanged: ((Bool) -> Void)? = nil,
        onDictationError: ((String) -> Void)? = nil,
        dictationMode: MirageDictationMode = .best,
        maxDrawableSize: CGSize? = nil
    ) {
        self.session = session
        self.sessionStore = sessionStore
        self.clientService = clientService
        self.isDesktopStream = isDesktopStream
        self.desktopStreamMode = desktopStreamMode
        self.onExitDesktopStream = onExitDesktopStream
        self.onToggleDictationShortcut = onToggleDictationShortcut
        self.desktopExitShortcut = desktopExitShortcut
        self.dictationShortcut = dictationShortcut
        self.onInputActivity = onInputActivity
        self.onDirectTouchActivity = onDirectTouchActivity
        self.onHardwareKeyboardPresenceChanged = onHardwareKeyboardPresenceChanged
        self.onSoftwareKeyboardVisibilityChanged = onSoftwareKeyboardVisibilityChanged
        self.dockSnapEnabled = dockSnapEnabled
        self.directTouchInputMode = directTouchInputMode ??
            (usesVirtualTrackpad ? .dragCursor : .normal)
        self.softwareKeyboardVisible = softwareKeyboardVisible
        self.pencilInputMode = pencilInputMode
        self.dictationToggleRequestID = dictationToggleRequestID
        self.onDictationStateChanged = onDictationStateChanged
        self.onDictationError = onDictationError
        self.dictationMode = dictationMode
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
                    Task { @MainActor [clientService] in
                        await Task.yield()
                        clientService.updateStreamRefreshRateOverride(
                            streamID: session.streamID,
                            maxRefreshRate: override
                        )
                    }
                },
                cursorStore: clientService.cursorStore,
                cursorPositionStore: clientService.cursorPositionStore,
                onBecomeActive: {
                    handleForegroundRecovery()
                },
                onHardwareKeyboardPresenceChanged: onHardwareKeyboardPresenceChanged,
                onSoftwareKeyboardVisibilityChanged: onSoftwareKeyboardVisibilityChanged,
                onDirectTouchActivity: onDirectTouchActivity,
                dockSnapEnabled: dockSnapEnabled,
                usesVirtualTrackpad: directTouchInputMode == .dragCursor,
                directTouchInputMode: directTouchInputMode,
                softwareKeyboardVisible: softwareKeyboardVisible,
                pencilInputMode: pencilInputMode,
                dictationToggleRequestID: dictationToggleRequestID,
                onDictationStateChanged: onDictationStateChanged,
                onDictationError: onDictationError,
                dictationMode: dictationMode,
                cursorLockEnabled: isDesktopStream && desktopStreamMode == .secondary,
                maxDrawableSize: maxDrawableSize,
                latencyMode: clientService.latencyMode
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
        .onChange(of: sessionStore.sessionMinSizes[session.id]) { _, minSize in
            handleResizeAcknowledgement(minSize)
        }
        .onChange(of: sessionStore.sessionMinSizeUpdateGenerations[session.id]) { _, _ in
            handleResizeAcknowledgement(sessionStore.sessionMinSizes[session.id])
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
            desktopResizeAckTimeoutTask?.cancel()
            desktopResizeAckTimeoutTask = nil
            if awaitingDesktopResizeAck {
                finishDesktopResizeAwaitingAck()
            } else {
                if isResizing { isResizing = false }
            }
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
        onInputActivity?(event)

        if case let .keyDown(keyEvent) = event {
            if isDesktopStream, desktopExitShortcut.matches(keyEvent) {
                onExitDesktopStream?()
                return
            }
            if dictationShortcut.matches(keyEvent) {
                onToggleDictationShortcut?()
                return
            }
        }

        if MirageTypingBurstClassifier.shouldTrigger(for: event) {
            MirageFrameCache.shared.noteTypingBurstActivity(for: session.streamID)
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
            if mouseEvent.stylus != nil {
                clientService.sendInputFireAndForget(.mouseMoved(mouseEvent), forStream: session.streamID)
            } else {
                pointerInputSampler.handle(kind: .move, event: mouseEvent) { resampledEvent in
                    clientService.sendInputFireAndForget(.mouseMoved(resampledEvent), forStream: session.streamID)
                }
            }
            return
        case let .mouseDragged(mouseEvent):
            if mouseEvent.stylus != nil {
                clientService.sendInputFireAndForget(.mouseDragged(mouseEvent), forStream: session.streamID)
            } else {
                pointerInputSampler.handle(kind: .leftDrag, event: mouseEvent) { resampledEvent in
                    clientService.sendInputFireAndForget(.mouseDragged(resampledEvent), forStream: session.streamID)
                }
            }
            return
        case let .rightMouseDragged(mouseEvent):
            if mouseEvent.stylus != nil {
                clientService.sendInputFireAndForget(.rightMouseDragged(mouseEvent), forStream: session.streamID)
            } else {
                pointerInputSampler.handle(kind: .rightDrag, event: mouseEvent) { resampledEvent in
                    clientService.sendInputFireAndForget(.rightMouseDragged(resampledEvent), forStream: session.streamID)
                }
            }
            return
        case let .otherMouseDragged(mouseEvent):
            if mouseEvent.stylus != nil {
                clientService.sendInputFireAndForget(.otherMouseDragged(mouseEvent), forStream: session.streamID)
            } else {
                pointerInputSampler.handle(kind: .otherDrag, event: mouseEvent) { resampledEvent in
                    clientService.sendInputFireAndForget(.otherMouseDragged(resampledEvent), forStream: session.streamID)
                }
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
        if let screenPointSize = metrics.screenPointSize,
           screenPointSize.width > 0,
           screenPointSize.height > 0 {
            MirageClientService.lastKnownScreenPointSize = screenPointSize
        }
        if let screenScale = metrics.screenScale, screenScale > 0 {
            MirageClientService.lastKnownScreenScale = screenScale
        }
        if let nativePixelSize = metrics.screenNativePixelSize,
           nativePixelSize.width > 0,
           nativePixelSize.height > 0 {
            MirageClientService.lastKnownScreenNativePixelSize = nativePixelSize
        }
        if let nativeScale = metrics.screenNativeScale, nativeScale > 0 {
            MirageClientService.lastKnownScreenNativeScale = nativeScale
        }
        let fallbackScreenSize = metrics.screenPointSize ?? viewSize
        #else
        let screenBounds = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let fallbackScreenSize = screenBounds.size
        #endif

        let effectiveScreenSize = (viewSize == .zero) ? fallbackScreenSize : viewSize

        Task { @MainActor [clientService] in
            await Task.yield()
            guard allowsResizeEvents else { return }

            if session.hasReceivedFirstFrame, !isDesktopStream {
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

            let desktopDisplaySize = isDesktopStream
                ? clientService.preferredDesktopDisplayResolution(for: viewSize)
                : .zero
            let streamScaleReferenceSize = isDesktopStream ? desktopDisplaySize : viewSize
            if !isDesktopStream || !awaitingDesktopResizeAck {
                scheduleStreamScaleUpdate(for: streamScaleReferenceSize)
            }

            guard isDesktopStream else { return }

            let preferredDisplaySize = desktopDisplaySize
            guard preferredDisplaySize.width > 0, preferredDisplaySize.height > 0 else { return }
            latestDrawableDisplaySize = preferredDisplaySize

            let acknowledgedPixelSize = currentDesktopAcknowledgedPixelSize()
            let pointScale = desktopPointScale(for: preferredDisplaySize)
            switch desktopResizeRequestDecision(
                targetDisplaySize: preferredDisplaySize,
                acknowledgedPixelSize: acknowledgedPixelSize,
                pointScale: pointScale,
                mismatchThresholdPoints: desktopResizeConvergenceTolerance
            ) {
            case .skipNoOp:
                displayResolutionTask?.cancel()
                displayResolutionTask = nil
                lastSentDisplayResolution = preferredDisplaySize
                if awaitingDesktopResizeAck { finishDesktopResizeAwaitingAck() }
                else if isResizing { isResizing = false }
                return
            case .send:
                guard lastSentDisplayResolution != preferredDisplaySize else { return }
                break
            }

            displayResolutionTask?.cancel()
            displayResolutionTask = Task { @MainActor in
                do {
                    try await Task.sleep(for: .milliseconds(200))
                } catch {
                    return
                }

                let latestAcknowledgedPixelSize = currentDesktopAcknowledgedPixelSize()
                let latestPointScale = desktopPointScale(for: preferredDisplaySize)
                let latestDecision = desktopResizeRequestDecision(
                    targetDisplaySize: preferredDisplaySize,
                    acknowledgedPixelSize: latestAcknowledgedPixelSize,
                    pointScale: latestPointScale,
                    mismatchThresholdPoints: desktopResizeConvergenceTolerance
                )
                if latestDecision == .skipNoOp {
                    lastSentDisplayResolution = preferredDisplaySize
                    if awaitingDesktopResizeAck { finishDesktopResizeAwaitingAck() }
                    else if isResizing { isResizing = false }
                    return
                }

                guard lastSentDisplayResolution != preferredDisplaySize else {
                    if !awaitingDesktopResizeAck, isResizing { isResizing = false }
                    return
                }
                sentDesktopPostAckCorrection = false
                beginDesktopResizeAwaitingAck()
                lastSentDisplayResolution = preferredDisplaySize
                try? await clientService.sendDisplayResolutionChange(
                    streamID: session.streamID,
                    newResolution: preferredDisplaySize
                )
            }
        }
    }

    private func beginDesktopResizeAwaitingAck() {
        awaitingDesktopResizeAck = true
        isResizing = true
        desktopResizeAckTimeoutTask?.cancel()
        desktopResizeAckTimeoutTask = Task { @MainActor in
            do {
                try await Task.sleep(for: desktopResizeAckTimeout)
            } catch {
                return
            }
            guard awaitingDesktopResizeAck else { return }
            MirageLogger.client("Desktop resize ack timeout for stream \(session.streamID)")
            finishDesktopResizeAwaitingAck()
        }
    }

    private func finishDesktopResizeAwaitingAck() {
        desktopResizeAckTimeoutTask?.cancel()
        desktopResizeAckTimeoutTask = nil
        awaitingDesktopResizeAck = false
        sentDesktopPostAckCorrection = false
        if isResizing { isResizing = false }
        if latestDrawableDisplaySize.width > 0, latestDrawableDisplaySize.height > 0 {
            scheduleStreamScaleUpdate(for: latestDrawableDisplaySize)
        }
    }

    private func handleResizeAcknowledgement(_ minSize: CGSize?) {
        guard isDesktopStream else {
            if isResizing { isResizing = false }
            return
        }
        guard awaitingDesktopResizeAck else { return }
        guard let minSize, minSize.width > 0, minSize.height > 0 else { return }

        let targetDisplaySize: CGSize = if latestDrawableDisplaySize.width > 0, latestDrawableDisplaySize.height > 0 {
            latestDrawableDisplaySize
        } else {
            lastSentDisplayResolution
        }
        let pointScale = desktopPointScale(for: targetDisplaySize)
        let acknowledgedDisplaySize = CGSize(
            width: minSize.width / pointScale,
            height: minSize.height / pointScale
        )

        switch desktopResizeAckDecision(
            acknowledgedDisplaySize: acknowledgedDisplaySize,
            targetDisplaySize: targetDisplaySize,
            correctionAlreadySent: sentDesktopPostAckCorrection,
            mismatchThresholdPoints: desktopResizeConvergenceTolerance
        ) {
        case .converged:
            finishDesktopResizeAwaitingAck()
        case .requestCorrection:
            sentDesktopPostAckCorrection = true
            beginDesktopResizeAwaitingAck()
            lastSentDisplayResolution = targetDisplaySize
            MirageLogger
                .client(
                    "Desktop resize ack mismatch for stream \(session.streamID); sending one-shot correction to " +
                        "\(Int(targetDisplaySize.width))x\(Int(targetDisplaySize.height)) pts"
                )
            Task { @MainActor [clientService] in
                try? await clientService.sendDisplayResolutionChange(
                    streamID: session.streamID,
                    newResolution: targetDisplaySize
                )
            }
        case .waitForTimeout:
            MirageLogger.client("Desktop resize ack mismatch persisted after correction for stream \(session.streamID)")
        }
    }

    private func currentDesktopAcknowledgedPixelSize() -> CGSize {
        if let desktopResolution = clientService.desktopStreamResolution,
           desktopResolution.width > 0,
           desktopResolution.height > 0 {
            return desktopResolution
        }

        if let minimumSize = sessionStore.sessionMinSizes[session.id],
           minimumSize.width > 0,
           minimumSize.height > 0 {
            return minimumSize
        }

        return .zero
    }

    private func resolvedDesktopStreamScale(for displaySize: CGSize) -> CGFloat {
        guard let maxDrawableSize,
              maxDrawableSize.width > 0,
              maxDrawableSize.height > 0,
              displaySize.width > 0,
              displaySize.height > 0 else {
            return 1.0
        }

        let basePoints = clientService.scaledDisplayResolution(displaySize)
        guard basePoints.width > 0, basePoints.height > 0 else { return 1.0 }

        let basePixels = clientService.virtualDisplayPixelResolution(for: basePoints)
        guard basePixels.width > 0, basePixels.height > 0 else { return 1.0 }

        let widthScale = maxDrawableSize.width / basePixels.width
        let heightScale = maxDrawableSize.height / basePixels.height
        return clientService.clampStreamScale(min(1.0, widthScale, heightScale))
    }

    private func desktopPointScale(for displaySize: CGSize) -> CGFloat {
        let basePixels = clientService.virtualDisplayPixelResolution(for: displaySize)
        let widthScale = displaySize.width > 0 ? basePixels.width / displaySize.width : 1.0
        let heightScale = displaySize.height > 0 ? basePixels.height / displaySize.height : 1.0
        let virtualDisplayScaleFactor = max(1.0, widthScale, heightScale)
        let streamScale = resolvedDesktopStreamScale(for: displaySize)
        return max(1.0, virtualDisplayScaleFactor * streamScale)
    }

    private func scheduleStreamScaleUpdate(for displaySize: CGSize) {
        guard let maxDrawableSize,
              maxDrawableSize.width > 0,
              maxDrawableSize.height > 0,
              displaySize.width > 0,
              displaySize.height > 0 else {
            return
        }

        let basePoints = clientService.scaledDisplayResolution(displaySize)
        guard basePoints.width > 0, basePoints.height > 0 else { return }

        let basePixels = clientService.virtualDisplayPixelResolution(for: basePoints)
        let clampedScale = resolvedDesktopStreamScale(for: displaySize)

        let rawTargetSize = CGSize(
            width: basePixels.width * clampedScale,
            height: basePixels.height * clampedScale
        )
        let alignedTargetSize = CGSize(
            width: min(maxDrawableSize.width, alignedEven(rawTargetSize.width)),
            height: min(maxDrawableSize.height, alignedEven(rawTargetSize.height))
        )

        if isDesktopStream {
            let acknowledgedPixelSize = currentDesktopAcknowledgedPixelSize()
            if approximatelyEqualPixelSizes(acknowledgedPixelSize, alignedTargetSize) {
                lastSentEncodedPixelSize = alignedTargetSize
                streamScaleTask?.cancel()
                streamScaleTask = nil
                return
            }
        }

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

    private func approximatelyEqualPixelSizes(
        _ lhs: CGSize,
        _ rhs: CGSize,
        tolerance: CGFloat = 2
    )
    -> Bool {
        guard lhs.width > 0, lhs.height > 0, rhs.width > 0, rhs.height > 0 else { return false }
        return abs(lhs.width - rhs.width) <= tolerance &&
            abs(lhs.height - rhs.height) <= tolerance
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
        if awaitingDesktopResizeAck {
            finishDesktopResizeAwaitingAck()
        } else if isResizing {
            isResizing = false
        }

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
