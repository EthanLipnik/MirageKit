//
//  InputStreamCache.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/5/26.
//

import Foundation
import MirageKit

#if os(macOS)

struct AppStreamInputOverlayRegion: Sendable, Equatable {
    let window: MirageWindow
    let normalizedRect: CGRect
    let zIndex: Int
    let receivesKeyboardFocus: Bool

    init(
        window: MirageWindow,
        normalizedRect: CGRect,
        zIndex: Int,
        receivesKeyboardFocus: Bool
    ) {
        self.window = window
        self.normalizedRect = normalizedRect
        self.zIndex = zIndex
        self.receivesKeyboardFocus = receivesKeyboardFocus
    }
}

/// Cached stream entry with all info needed for fast input mapping
struct InputStreamCacheEntry {
    var window: MirageWindow
    var client: MirageConnectedClient
    /// The content rect within the capture buffer (for offset adjustment)
    /// Origin indicates padding at top-left, size is the actual content dimensions
    var contentRect: CGRect = .zero
    var auxiliaryOverlayRegions: [AppStreamInputOverlayRegion] = []
}

struct AppStreamResolvedInputTarget: Sendable {
    let event: MirageInputEvent
    let window: MirageWindow
    let client: MirageConnectedClient
}

enum AppStreamInputOverlayRouting {
    struct Result: Sendable {
        let event: MirageInputEvent
        let window: MirageWindow
    }

    static func route(
        event: MirageInputEvent,
        parentWindow: MirageWindow,
        regions: [AppStreamInputOverlayRegion]
    ) -> Result {
        let sortedRegions = regions
            .filter { isValidNormalizedRect($0.normalizedRect) }
            .sorted { lhs, rhs in
                if lhs.zIndex != rhs.zIndex { return lhs.zIndex > rhs.zIndex }
                return lhs.window.id > rhs.window.id
            }

        switch event {
        case .keyDown,
             .keyUp,
             .flagsChanged,
             .windowFocus:
            if let keyboardRegion = sortedRegions.first(where: \.receivesKeyboardFocus) ?? sortedRegions.first {
                return Result(event: event, window: keyboardRegion.window)
            }
            return Result(event: event, window: parentWindow)
        case .mouseDown,
             .mouseUp,
             .mouseMoved,
             .mouseDragged,
             .rightMouseDown,
             .rightMouseUp,
             .rightMouseDragged,
             .otherMouseDown,
             .otherMouseUp,
             .otherMouseDragged,
             .pointerSampleBatch,
             .scrollWheel,
             .magnify,
             .rotate,
             .swipe:
            guard let location = hitTestLocation(for: event),
                  let region = sortedRegions.first(where: { $0.normalizedRect.contains(location) }),
                  let rewrittenEvent = rewrite(event: event, through: region.normalizedRect) else {
                return Result(event: event, window: parentWindow)
            }
            return Result(event: rewrittenEvent, window: region.window)
        case .hostSystemAction,
             .pixelResize,
             .relativeResize,
             .windowResize:
            return Result(event: event, window: parentWindow)
        }
    }

    private static func hitTestLocation(for event: MirageInputEvent) -> CGPoint? {
        switch event {
        case let .mouseDown(event),
             let .mouseUp(event),
             let .mouseMoved(event),
             let .mouseDragged(event),
             let .rightMouseDown(event),
             let .rightMouseUp(event),
             let .rightMouseDragged(event),
             let .otherMouseDown(event),
             let .otherMouseUp(event),
             let .otherMouseDragged(event):
            event.location
        case let .pointerSampleBatch(batch):
            batch.lastLocation
        case let .scrollWheel(event):
            event.location
        case let .magnify(event):
            event.location
        case let .rotate(event):
            event.location
        case let .swipe(event):
            event.location
        case .flagsChanged,
             .hostSystemAction,
             .keyDown,
             .keyUp,
             .pixelResize,
             .relativeResize,
             .windowFocus,
             .windowResize:
            nil
        }
    }

    private static func rewrite(
        event: MirageInputEvent,
        through rect: CGRect
    ) -> MirageInputEvent? {
        switch event {
        case let .mouseDown(event):
            .mouseDown(rewrite(mouseEvent: event, through: rect))
        case let .mouseUp(event):
            .mouseUp(rewrite(mouseEvent: event, through: rect))
        case let .mouseMoved(event):
            .mouseMoved(rewrite(mouseEvent: event, through: rect))
        case let .mouseDragged(event):
            .mouseDragged(rewrite(mouseEvent: event, through: rect))
        case let .rightMouseDown(event):
            .rightMouseDown(rewrite(mouseEvent: event, through: rect))
        case let .rightMouseUp(event):
            .rightMouseUp(rewrite(mouseEvent: event, through: rect))
        case let .rightMouseDragged(event):
            .rightMouseDragged(rewrite(mouseEvent: event, through: rect))
        case let .otherMouseDown(event):
            .otherMouseDown(rewrite(mouseEvent: event, through: rect))
        case let .otherMouseUp(event):
            .otherMouseUp(rewrite(mouseEvent: event, through: rect))
        case let .otherMouseDragged(event):
            .otherMouseDragged(rewrite(mouseEvent: event, through: rect))
        case let .pointerSampleBatch(batch):
            .pointerSampleBatch(rewrite(pointerSampleBatch: batch, through: rect))
        case let .scrollWheel(event):
            .scrollWheel(rewrite(scrollEvent: event, through: rect))
        case let .magnify(event):
            .magnify(rewrite(magnifyEvent: event, through: rect))
        case let .rotate(event):
            .rotate(rewrite(rotateEvent: event, through: rect))
        case let .swipe(event):
            .swipe(rewrite(swipeEvent: event, through: rect))
        case .flagsChanged,
             .hostSystemAction,
             .keyDown,
             .keyUp,
             .pixelResize,
             .relativeResize,
             .windowFocus,
             .windowResize:
            nil
        }
    }

    private static func rewrite(mouseEvent event: MirageMouseEvent, through rect: CGRect) -> MirageMouseEvent {
        MirageMouseEvent(
            button: event.button,
            location: map(location: event.location, through: rect),
            clickCount: event.clickCount,
            modifiers: event.modifiers,
            pressure: event.pressure,
            stylus: event.stylus,
            timestamp: event.timestamp
        )
    }

    private static func rewrite(scrollEvent event: MirageScrollEvent, through rect: CGRect) -> MirageScrollEvent {
        MirageScrollEvent(
            deltaX: event.deltaX,
            deltaY: event.deltaY,
            location: event.location.map { map(location: $0, through: rect) },
            phase: event.phase,
            momentumPhase: event.momentumPhase,
            modifiers: event.modifiers,
            isPrecise: event.isPrecise,
            timestamp: event.timestamp
        )
    }

    private static func rewrite(magnifyEvent event: MirageMagnifyEvent, through rect: CGRect) -> MirageMagnifyEvent {
        MirageMagnifyEvent(
            magnification: event.magnification,
            location: event.location.map { map(location: $0, through: rect) },
            phase: event.phase,
            modifiers: event.modifiers,
            timestamp: event.timestamp
        )
    }

    private static func rewrite(rotateEvent event: MirageRotateEvent, through rect: CGRect) -> MirageRotateEvent {
        MirageRotateEvent(
            rotation: event.rotation,
            location: event.location.map { map(location: $0, through: rect) },
            phase: event.phase,
            modifiers: event.modifiers,
            timestamp: event.timestamp
        )
    }

    private static func rewrite(swipeEvent event: MirageSwipeEvent, through rect: CGRect) -> MirageSwipeEvent {
        MirageSwipeEvent(
            deltaX: event.deltaX,
            deltaY: event.deltaY,
            location: event.location.map { map(location: $0, through: rect) },
            phase: event.phase,
            modifiers: event.modifiers,
            timestamp: event.timestamp
        )
    }

    private static func rewrite(
        pointerSampleBatch batch: MiragePointerSampleBatch,
        through rect: CGRect
    ) -> MiragePointerSampleBatch {
        MiragePointerSampleBatch(
            phase: batch.phase,
            button: batch.button,
            modifiers: batch.modifiers,
            clickCount: batch.clickCount,
            isButtonPressed: batch.isButtonPressed,
            samples: batch.samples.map { sample in
                MiragePointerSample(
                    location: map(location: sample.location, through: rect),
                    pressure: sample.pressure,
                    stylus: sample.stylus,
                    timestamp: sample.timestamp
                )
            },
            timestamp: batch.timestamp
        )
    }

    private static func map(location: CGPoint, through rect: CGRect) -> CGPoint {
        CGPoint(
            x: (location.x - rect.minX) / rect.width,
            y: (location.y - rect.minY) / rect.height
        )
    }

    private static func isValidNormalizedRect(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite &&
            rect.origin.y.isFinite &&
            rect.width.isFinite &&
            rect.height.isFinite &&
            rect.width > 0 &&
            rect.height > 0
    }
}

/// Thread-safe cache for stream info used by fast input path
/// Using a class with lock for synchronous access from inputQueue
final class InputStreamCacheActor: @unchecked Sendable {
    private var cache: [StreamID: InputStreamCacheEntry] = [:]
    private let lock = NSLock()

    func set(_ streamID: StreamID, window: MirageWindow, client: MirageConnectedClient) {
        lock.lock()
        cache[streamID] = InputStreamCacheEntry(window: window, client: client)
        lock.unlock()
    }

    func remove(_ streamID: StreamID) {
        lock.lock()
        cache.removeValue(forKey: streamID)
        lock.unlock()
    }

    func get(_ streamID: StreamID) -> InputStreamCacheEntry? {
        lock.lock()
        defer { lock.unlock() }
        return cache[streamID]
    }

    func resolveInputTarget(streamID: StreamID, event: MirageInputEvent) -> AppStreamResolvedInputTarget? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = cache[streamID] else { return nil }
        let routed = AppStreamInputOverlayRouting.route(
            event: event,
            parentWindow: entry.window,
            regions: entry.auxiliaryOverlayRegions
        )
        return AppStreamResolvedInputTarget(
            event: routed.event,
            window: routed.window,
            client: entry.client
        )
    }

    func setAuxiliaryOverlayRegions(_ streamID: StreamID, regions: [AppStreamInputOverlayRegion]) {
        lock.lock()
        defer { lock.unlock() }
        guard var entry = cache[streamID] else { return }
        entry.auxiliaryOverlayRegions = regions
        cache[streamID] = entry
    }

    func clearAuxiliaryOverlayRegions(_ streamID: StreamID) {
        setAuxiliaryOverlayRegions(streamID, regions: [])
    }

    /// Update the window frame in the cache after window move/resize
    /// Critical for correct mouse coordinate translation after virtual display moves
    func updateWindowFrame(_ streamID: StreamID, newFrame: CGRect) {
        lock.lock()
        defer { lock.unlock() }
        guard var entry = cache[streamID] else { return }
        entry.window = MirageWindow(
            id: entry.window.id,
            title: entry.window.title,
            application: entry.window.application,
            frame: newFrame,
            isOnScreen: entry.window.isOnScreen,
            windowLayer: entry.window.windowLayer
        )
        cache[streamID] = entry
    }

    /// Update the content rect for a stream (for coordinate offset adjustment)
    /// Called when capture frames arrive with contentRect metadata
    func updateContentRect(_ streamID: StreamID, contentRect: CGRect) {
        lock.lock()
        defer { lock.unlock() }
        guard var entry = cache[streamID] else { return }
        entry.contentRect = contentRect
        cache[streamID] = entry
    }

    /// Get stream ID for a given window ID (for updating frame by windowID)
    func getStreamID(forWindowID windowID: WindowID) -> StreamID? {
        lock.lock()
        defer { lock.unlock() }
        return cache.first(where: { $0.value.window.id == windowID })?.key
    }
}

#endif
