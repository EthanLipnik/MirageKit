//
//  MirageStreamContentView.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/16/26.
//

import SwiftUI
import CoreVideo
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

    /// Content rectangle for current frame (for SCK black bar cropping).
    @State private var contentRect: CGRect = .zero

    /// Last relative sizing sent to host - prevents duplicate resize events.
    @State private var lastSentAspectRatio: CGFloat = 0
    @State private var lastSentRelativeScale: CGFloat = 0
    @State private var lastSentPixelSize: CGSize = .zero

    /// Debounce task for resize events - only sends after user stops resizing.
    @State private var resizeDebounceTask: Task<Void, Never>?

    /// Whether the client is currently waiting for host to complete resize.
    @State private var isResizing: Bool = false

    /// Whether we've received at least one frame (prevents resize blocking on initial load).
    @State private var hasReceivedFirstFrame: Bool = false

    /// The frame to display - frozen during resize, updated right before unblur.
    @State private var displayedFrame: CVPixelBuffer?

    /// Content rect for the displayed frame (frozen during resize).
    @State private var displayedContentRect: CGRect = .zero

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
    public init(
        session: MirageStreamSessionState,
        sessionStore: MirageClientSessionStore,
        clientService: MirageClientService,
        isDesktopStream: Bool = false,
        onExitDesktopStream: (() -> Void)? = nil
    ) {
        self.session = session
        self.sessionStore = sessionStore
        self.clientService = clientService
        self.isDesktopStream = isDesktopStream
        self.onExitDesktopStream = onExitDesktopStream
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
                }
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
            displayedFrame = newFrame
            contentRect = sessionStore.contentRects[session.id] ?? .zero

            if !hasReceivedFirstFrame && newFrame != nil {
                hasReceivedFirstFrame = true
            }

            if !isResizing {
                displayedFrame = newFrame
                displayedContentRect = contentRect
            }
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
        clientService.sendInputFireAndForget(event, forStream: session.streamID)
    }

    private func handleDrawableSizeChanged(_ pixelSize: CGSize) {
        guard pixelSize.width > 0, pixelSize.height > 0 else { return }

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

        resizeDebounceTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(200))
            } catch {
                return
            }

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

            let (lastAspectRatio, lastRelativeScale, lastPixelSize) = await MainActor.run {
                (lastSentAspectRatio, lastSentRelativeScale, lastSentPixelSize)
            }
            let isInitialLayout = lastAspectRatio == 0 && lastRelativeScale == 0 && lastPixelSize == .zero
            if isInitialLayout {
                await MainActor.run {
                    lastSentAspectRatio = aspectRatio
                    lastSentRelativeScale = relativeScale
                    lastSentPixelSize = cappedPixelSize
                }
                return
            }

            let aspectChanged = abs(aspectRatio - lastAspectRatio) > 0.01
            let scaleChanged = abs(relativeScale - lastRelativeScale) > 0.01
            let pixelChanged = cappedPixelSize != lastPixelSize
            guard aspectChanged || scaleChanged || pixelChanged else { return }

            await MainActor.run {
                lastSentAspectRatio = aspectRatio
                lastSentRelativeScale = relativeScale
                lastSentPixelSize = cappedPixelSize
            }

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
            await MainActor.run {
                if isResizing {
                    displayedFrame = sessionStore.latestFrames[session.id]
                    displayedContentRect = contentRect
                    isResizing = false
                }
            }
        }
    }

#if os(iOS)
    private func handleForegroundRecovery() {
        if isResizing {
            displayedFrame = sessionStore.latestFrames[session.id]
            displayedContentRect = contentRect
            isResizing = false
        }

        resizeDebounceTask?.cancel()
        resizeDebounceTask = nil

        clientService.requestStreamRecovery(for: session.streamID)
    }
#endif
}
