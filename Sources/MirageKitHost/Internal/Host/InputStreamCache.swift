//
//  InputStreamCache.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/5/26.
//

import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageKit
import MirageKitClientPresentation
import MirageMedia
import MirageWire
import Foundation

#if os(macOS)

struct AppStreamInputOverlayRegion: Equatable {
    /// Auxiliary child window that receives input when the region matches.
    let window: MirageMedia.MirageWindow
    /// Child window bounds in the parent stream's normalized coordinate space.
    let normalizedRect: CGRect
    /// Higher values receive hit-test priority when regions overlap.
    let zIndex: Int
    /// Whether keyboard-like events should prefer this region over visual z-order.
    let receivesKeyboardFocus: Bool
}

/// Cached stream entry with the window and client context needed for the fast input path.
struct InputStreamCacheEntry {
    /// Parent stream window used as the default input target.
    var window: MirageMedia.MirageWindow
    /// Client authorized to send input for this stream.
    var client: MirageConnectedClient
    /// Auxiliary overlay hit-test regions associated with this stream.
    var auxiliaryOverlayRegions: [AppStreamInputOverlayRegion] = []
}

/// Input target resolved from a stream ID after auxiliary overlay hit testing.
struct AppStreamResolvedInputTarget {
    /// Possibly rewritten input event for the resolved target window.
    let event: MirageInput.MirageInputEvent
    /// Host window that should receive the event.
    let window: MirageMedia.MirageWindow
    /// Client authorized for the stream.
    let client: MirageConnectedClient
}

/// Routes parent-stream input into auxiliary app-stream overlay regions.
enum AppStreamInputOverlayRouting {
    /// Routed event and destination host window.
    struct Result {
        let event: MirageInput.MirageInputEvent
        let window: MirageMedia.MirageWindow
    }

    /// Returns the destination window and rewrites pointer coordinates into child-region space when needed.
    static func route(
        event: MirageInput.MirageInputEvent,
        parentWindow: MirageMedia.MirageWindow,
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

    /// Returns the normalized pointer location used to hit-test overlay regions.
    private static func hitTestLocation(for event: MirageInput.MirageInputEvent) -> CGPoint? {
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

    /// Rewrites a pointer-like event from parent coordinates into an overlay region.
    private static func rewrite(
        event: MirageInput.MirageInputEvent,
        through rect: CGRect
    ) -> MirageInput.MirageInputEvent? {
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

    /// Rewrites a mouse event location through an overlay region.
    private static func rewrite(mouseEvent event: MirageInput.MirageMouseEvent, through rect: CGRect) -> MirageInput.MirageMouseEvent {
        MirageInput.MirageMouseEvent(
            button: event.button,
            location: map(location: event.location, through: rect),
            clickCount: event.clickCount,
            modifiers: event.modifiers,
            pressure: event.pressure,
            stylus: event.stylus,
            timestamp: event.timestamp
        )
    }

    /// Rewrites a scroll event location through an overlay region.
    private static func rewrite(scrollEvent event: MirageInput.MirageScrollEvent, through rect: CGRect) -> MirageInput.MirageScrollEvent {
        MirageInput.MirageScrollEvent(
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

    /// Rewrites a magnify event location through an overlay region.
    private static func rewrite(magnifyEvent event: MirageInput.MirageMagnifyEvent, through rect: CGRect) -> MirageInput.MirageMagnifyEvent {
        MirageInput.MirageMagnifyEvent(
            magnification: event.magnification,
            location: event.location.map { map(location: $0, through: rect) },
            phase: event.phase,
            modifiers: event.modifiers,
            timestamp: event.timestamp
        )
    }

    /// Rewrites a rotate event location through an overlay region.
    private static func rewrite(rotateEvent event: MirageInput.MirageRotateEvent, through rect: CGRect) -> MirageInput.MirageRotateEvent {
        MirageInput.MirageRotateEvent(
            rotation: event.rotation,
            location: event.location.map { map(location: $0, through: rect) },
            phase: event.phase,
            modifiers: event.modifiers,
            timestamp: event.timestamp
        )
    }

    /// Rewrites a swipe event location through an overlay region.
    private static func rewrite(swipeEvent event: MirageInput.MirageSwipeEvent, through rect: CGRect) -> MirageInput.MirageSwipeEvent {
        MirageInput.MirageSwipeEvent(
            deltaX: event.deltaX,
            deltaY: event.deltaY,
            location: event.location.map { map(location: $0, through: rect) },
            phase: event.phase,
            modifiers: event.modifiers,
            timestamp: event.timestamp
        )
    }

    /// Rewrites every sample in a pointer batch through an overlay region.
    private static func rewrite(
        pointerSampleBatch batch: MirageInput.MiragePointerSampleBatch,
        through rect: CGRect
    ) -> MirageInput.MiragePointerSampleBatch {
        MirageInput.MiragePointerSampleBatch(
            phase: batch.phase,
            button: batch.button,
            modifiers: batch.modifiers,
            clickCount: batch.clickCount,
            isButtonPressed: batch.isButtonPressed,
            samples: batch.samples.map { sample in
                MirageInput.MiragePointerSample(
                    location: map(location: sample.location, through: rect),
                    pressure: sample.pressure,
                    stylus: sample.stylus,
                    timestamp: sample.timestamp
                )
            },
            timestamp: batch.timestamp
        )
    }

    /// Maps a parent normalized location into overlay-local normalized coordinates.
    private static func map(location: CGPoint, through rect: CGRect) -> CGPoint {
        CGPoint(
            x: (location.x - rect.minX) / rect.width,
            y: (location.y - rect.minY) / rect.height
        )
    }

    /// Returns whether a normalized overlay rectangle can be used for hit testing.
    private static func isValidNormalizedRect(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite &&
            rect.origin.y.isFinite &&
            rect.width.isFinite &&
            rect.height.isFinite &&
            rect.width > 0 &&
            rect.height > 0
    }
}

/// Lock-backed stream lookup cache used by the synchronous fast input path.
final class InputStreamCache: @unchecked Sendable {
    private var cache: [StreamID: InputStreamCacheEntry] = [:]
    private let lock = NSLock()

    /// Stores the current input mapping for a stream.
    func set(_ streamID: StreamID, window: MirageMedia.MirageWindow, client: MirageConnectedClient) {
        lock.lock()
        defer { lock.unlock() }
        cache[streamID] = InputStreamCacheEntry(window: window, client: client)
    }

    /// Removes cached input mapping when a stream stops.
    func remove(_ streamID: StreamID) {
        lock.lock()
        defer { lock.unlock() }
        cache.removeValue(forKey: streamID)
    }

    /// Returns the cached input mapping for a stream.
    func entry(for streamID: StreamID) -> InputStreamCacheEntry? {
        lock.lock()
        defer { lock.unlock() }
        return cache[streamID]
    }

    /// Resolves the stream's current target window and rewrites the event for auxiliary overlays.
    func resolveInputTarget(streamID: StreamID, event: MirageInput.MirageInputEvent) -> AppStreamResolvedInputTarget? {
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

    /// Replaces auxiliary overlay routing regions for a parent app stream.
    func setAuxiliaryOverlayRegions(_ streamID: StreamID, regions: [AppStreamInputOverlayRegion]) {
        lock.lock()
        defer { lock.unlock() }
        guard var entry = cache[streamID] else { return }
        entry.auxiliaryOverlayRegions = regions
        cache[streamID] = entry
    }

    /// Updates a cached window frame after host-side move or resize changes.
    func updateWindowFrame(_ streamID: StreamID, newFrame: CGRect) {
        lock.lock()
        defer { lock.unlock() }
        guard var entry = cache[streamID] else { return }
        entry.window = MirageMedia.MirageWindow(
            id: entry.window.id,
            title: entry.window.title,
            application: entry.window.application,
            frame: newFrame,
            isOnScreen: entry.window.isOnScreen,
            windowLayer: entry.window.windowLayer
        )
        cache[streamID] = entry
    }

    /// Returns the stream ID currently associated with a host window ID.
    func streamID(forWindowID windowID: WindowID) -> StreamID? {
        lock.lock()
        defer { lock.unlock() }
        return cache.first(where: { $0.value.window.id == windowID })?.key
    }
}

#endif
