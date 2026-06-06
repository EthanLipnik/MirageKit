//
//  StreamContextMosaicSemanticSnapshotter.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 6/6/26.
//

import CoreGraphics
import Foundation
import MirageCore
import MirageMedia

#if os(macOS)
import ApplicationServices

struct StreamContextMosaicSemanticSnapshot: Sendable, Equatable {
    let candidates: [StreamContextMosaicSemanticCandidate]
    let isTransientSystemState: Bool
}

struct StreamContextMosaicSemanticElementObservation: Sendable, Equatable {
    let id: String
    let role: String
    let frame: CGRect
}

struct StreamContextMosaicSemanticWindowObservation: Sendable, Equatable {
    let windowID: WindowID
    let ownerName: String?
    let ownerProcessID: pid_t?
    let frame: CGRect
    let layer: Int
    let alpha: CGFloat
    let isOnScreen: Bool
    let orderIndex: Int
    let role: String?
    let subrole: String?
    let isFocused: Bool
    let isMain: Bool
    let isModal: Bool
    let children: [StreamContextMosaicSemanticElementObservation]

    init(
        windowID: WindowID,
        ownerName: String?,
        ownerProcessID: pid_t?,
        frame: CGRect,
        layer: Int = 0,
        alpha: CGFloat = 1,
        isOnScreen: Bool = true,
        orderIndex: Int = 0,
        role: String? = nil,
        subrole: String? = nil,
        isFocused: Bool = false,
        isMain: Bool = false,
        isModal: Bool = false,
        children: [StreamContextMosaicSemanticElementObservation] = []
    ) {
        self.windowID = windowID
        self.ownerName = ownerName
        self.ownerProcessID = ownerProcessID
        self.frame = frame
        self.layer = layer
        self.alpha = alpha
        self.isOnScreen = isOnScreen
        self.orderIndex = orderIndex
        self.role = role
        self.subrole = subrole
        self.isFocused = isFocused
        self.isMain = isMain
        self.isModal = isModal
        self.children = children
    }
}

struct StreamContextMosaicSemanticSnapshotBuilder: Sendable {
    func snapshot(
        logicalSize: MiragePixelSize,
        captureBounds: CGRect,
        windows: [StreamContextMosaicSemanticWindowObservation]
    ) -> StreamContextMosaicSemanticSnapshot {
        guard !logicalSize.isEmpty,
              !captureBounds.isEmpty else {
            return StreamContextMosaicSemanticSnapshot(candidates: [], isTransientSystemState: false)
        }

        var candidates: [StreamContextMosaicSemanticCandidate] = []
        let visibleWindows = windows
            .filter { $0.isOnScreen && $0.alpha > 0.05 && !$0.frame.isEmpty }
            .sorted { lhs, rhs in lhs.orderIndex < rhs.orderIndex }

        for window in visibleWindows {
            guard let windowRect = pixelRect(window.frame, logicalSize: logicalSize, captureBounds: captureBounds) else {
                continue
            }
            let windowClass = semanticClass(for: window)
            let windowPriority = priority(for: window, semanticClass: windowClass)
            candidates.append(StreamContextMosaicSemanticCandidate(
                id: MirageMosaicTileID(rawValue: "window-\(window.windowID)"),
                rect: windowRect,
                semanticClass: windowClass,
                priority: windowPriority,
                codecStrategy: windowClass == .focusedWindow ? .verticalColumns : .singleUnit,
                commitPolicy: windowClass == .focusedWindow ? .atomic : .independent,
                isReliable: true
            ))

            for child in window.children {
                guard let childClass = semanticClass(forAXRole: child.role),
                      let childRect = pixelRect(
                        child.frame,
                        logicalSize: logicalSize,
                        captureBounds: captureBounds
                      ) else {
                    continue
                }
                candidates.append(StreamContextMosaicSemanticCandidate(
                    id: MirageMosaicTileID(rawValue: "window-\(window.windowID)-\(child.id)"),
                    rect: childRect,
                    semanticClass: childClass,
                    priority: priority(for: childClass, parentWindow: window),
                    codecStrategy: codecStrategy(for: childClass),
                    commitPolicy: commitPolicy(for: childClass),
                    isReliable: true
                ))
            }
        }

        return StreamContextMosaicSemanticSnapshot(
            candidates: candidates,
            isTransientSystemState: visibleWindows.contains { isTransientSystemWindow($0) }
        )
    }

    private func pixelRect(
        _ frame: CGRect,
        logicalSize: MiragePixelSize,
        captureBounds: CGRect
    ) -> MiragePixelRect? {
        let intersection = frame.standardized.intersection(captureBounds.standardized)
        guard !intersection.isEmpty else { return nil }

        let scaleX = CGFloat(logicalSize.width) / max(1, captureBounds.width)
        let scaleY = CGFloat(logicalSize.height) / max(1, captureBounds.height)
        let minX = Int(((intersection.minX - captureBounds.minX) * scaleX).rounded(.down))
        let minY = Int(((intersection.minY - captureBounds.minY) * scaleY).rounded(.down))
        let maxX = Int(((intersection.maxX - captureBounds.minX) * scaleX).rounded(.up))
        let maxY = Int(((intersection.maxY - captureBounds.minY) * scaleY).rounded(.up))
        let clampedMinX = min(max(0, minX), logicalSize.width)
        let clampedMinY = min(max(0, minY), logicalSize.height)
        let clampedMaxX = min(max(clampedMinX, maxX), logicalSize.width)
        let clampedMaxY = min(max(clampedMinY, maxY), logicalSize.height)
        let rect = MiragePixelRect(
            x: clampedMinX,
            y: clampedMinY,
            width: clampedMaxX - clampedMinX,
            height: clampedMaxY - clampedMinY
        )
        return rect.size.isEmpty ? nil : rect
    }

    private func semanticClass(for window: StreamContextMosaicSemanticWindowObservation) -> MirageMosaicSemanticClass {
        if window.ownerName == "Dock" { return .dock }
        if window.ownerName == "SystemUIServer" { return .menuBar }
        if window.isModal { return .sheet }
        if window.isFocused || window.isMain { return .focusedWindow }
        return .background
    }

    private func priority(
        for window: StreamContextMosaicSemanticWindowObservation,
        semanticClass: MirageMosaicSemanticClass
    ) -> MirageMosaicTilePriority {
        switch semanticClass {
        case .dock,
             .menuBar,
             .sheet,
             .popover,
             .menu:
            .transientChrome
        case .focusedWindow:
            .focusedContent
        default:
            window.isFocused || window.isMain ? .focusedContent : .semanticContent
        }
    }

    func semanticClass(forAXRole role: String) -> MirageMosaicSemanticClass? {
        switch role {
        case "AXScrollArea":
            .scrollView
        case "AXTextArea",
             "AXTextField",
             "AXStaticText":
            .textViewport
        case "AXToolbar":
            .toolbar
        case "AXTable",
             "AXOutline":
            .scrollView
        case "AXPopover":
            .popover
        case "AXSheet",
             "AXDialog":
            .sheet
        case "AXMenu",
             "AXMenuItem":
            .menu
        default:
            nil
        }
    }

    private func priority(
        for semanticClass: MirageMosaicSemanticClass,
        parentWindow: StreamContextMosaicSemanticWindowObservation
    ) -> MirageMosaicTilePriority {
        switch semanticClass {
        case .scrollView,
             .textViewport:
            parentWindow.isFocused || parentWindow.isMain ? .focusedContent : .semanticContent
        case .toolbar,
             .popover,
             .sheet,
             .menu:
            .transientChrome
        default:
            .semanticContent
        }
    }

    private func codecStrategy(for semanticClass: MirageMosaicSemanticClass) -> MirageMosaicCodecStrategy {
        switch semanticClass {
        case .scrollView:
            .verticalColumns
        default:
            .singleUnit
        }
    }

    private func commitPolicy(for semanticClass: MirageMosaicSemanticClass) -> MirageMosaicCommitPolicy {
        switch semanticClass {
        case .scrollView,
             .textViewport:
            .atomic
        default:
            .independent
        }
    }

    private func isTransientSystemWindow(_ window: StreamContextMosaicSemanticWindowObservation) -> Bool {
        guard window.ownerName == "Dock" else { return false }
        return window.layer > 10 && window.frame.width > 200 && window.frame.height > 200
    }
}

protocol StreamContextMosaicSemanticObservationProviding: Sendable {
    func observations() -> [StreamContextMosaicSemanticWindowObservation]
}

struct MacOSMosaicSemanticObservationProvider: StreamContextMosaicSemanticObservationProviding {
    func observations() -> [StreamContextMosaicSemanticWindowObservation] {
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }

        var observations: [StreamContextMosaicSemanticWindowObservation] = []
        observations.reserveCapacity(windowList.count)
        var accessibilityByPID: [pid_t: [WindowID: AXUIElement]] = [:]

        for (orderIndex, info) in windowList.enumerated() {
            guard let windowID = Self.windowID(from: info),
                  let frame = Self.frame(from: info) else {
                continue
            }
            let ownerPID = Self.ownerPID(from: info)
            let axWindow: AXUIElement?
            if let ownerPID {
                if accessibilityByPID[ownerPID] == nil {
                    let appElement = AXUIElementCreateApplication(ownerPID)
                    var indexedWindows: [WindowID: AXUIElement] = [:]
                    for axWindow in HostAccessibilityWindowLookup.windows(in: appElement) {
                        guard let windowID = HostAccessibilityWindowLookup.id(of: axWindow) else { continue }
                        indexedWindows[windowID] = axWindow
                    }
                    accessibilityByPID[ownerPID] = indexedWindows
                }
                axWindow = accessibilityByPID[ownerPID]?[windowID]
            } else {
                axWindow = nil
            }

            observations.append(StreamContextMosaicSemanticWindowObservation(
                windowID: windowID,
                ownerName: info[kCGWindowOwnerName as String] as? String,
                ownerProcessID: ownerPID,
                frame: frame,
                layer: info[kCGWindowLayer as String] as? Int ?? 0,
                alpha: Self.cgFloat(info[kCGWindowAlpha as String]) ?? 1,
                isOnScreen: info[kCGWindowIsOnscreen as String] as? Bool ?? true,
                orderIndex: orderIndex,
                role: axWindow.flatMap {
                    HostAccessibilityWindowLookup.stringAttribute(kAXRoleAttribute as CFString, from: $0)
                },
                subrole: axWindow.flatMap {
                    HostAccessibilityWindowLookup.stringAttribute(kAXSubroleAttribute as CFString, from: $0)
                },
                isFocused: axWindow.flatMap {
                    HostAccessibilityWindowLookup.boolAttribute(kAXFocusedAttribute as CFString, from: $0)
                } ?? false,
                isMain: axWindow.flatMap {
                    HostAccessibilityWindowLookup.boolAttribute(kAXMainAttribute as CFString, from: $0)
                } ?? false,
                isModal: axWindow.flatMap {
                    HostAccessibilityWindowLookup.boolAttribute("AXModal" as CFString, from: $0)
                } ?? false,
                children: axWindow.map(Self.semanticChildren(in:)) ?? []
            ))
        }

        return observations
    }

    private static func semanticChildren(in root: AXUIElement) -> [StreamContextMosaicSemanticElementObservation] {
        var observations: [StreamContextMosaicSemanticElementObservation] = []
        var queue = HostAccessibilityWindowLookup.elementArrayAttributeValue(
            root,
            attribute: kAXChildrenAttribute as CFString
        ) ?? []
        var visitedCount = 0
        while let element = queue.first, visitedCount < 96 {
            queue.removeFirst()
            visitedCount += 1
            let role = HostAccessibilityWindowLookup.stringAttribute(kAXRoleAttribute as CFString, from: element) ?? ""
            if let frame = HostAccessibilityWindowLookup.frame(of: element),
               StreamContextMosaicSemanticSnapshotBuilder().semanticClass(forAXRole: role) != nil {
                observations.append(StreamContextMosaicSemanticElementObservation(
                    id: "\(observations.count)-\(role)",
                    role: role,
                    frame: frame
                ))
            }
            if observations.count < 32,
               let children = HostAccessibilityWindowLookup.elementArrayAttributeValue(
                element,
                attribute: kAXChildrenAttribute as CFString
               ) {
                queue.append(contentsOf: children.prefix(16))
            }
        }
        return observations
    }

    private static func windowID(from info: [String: Any]) -> WindowID? {
        if let value = info[kCGWindowNumber as String] as? Int { return WindowID(value) }
        if let value = info[kCGWindowNumber as String] as? NSNumber { return WindowID(value.uint32Value) }
        return nil
    }

    private static func ownerPID(from info: [String: Any]) -> pid_t? {
        if let value = info[kCGWindowOwnerPID as String] as? Int { return pid_t(value) }
        if let value = info[kCGWindowOwnerPID as String] as? NSNumber { return pid_t(value.int32Value) }
        return nil
    }

    private static func frame(from info: [String: Any]) -> CGRect? {
        guard let bounds = info[kCGWindowBounds as String] as? [String: Any],
              let x = cgFloat(bounds["X"]),
              let y = cgFloat(bounds["Y"]),
              let width = cgFloat(bounds["Width"]),
              let height = cgFloat(bounds["Height"]) else {
            return nil
        }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private static func cgFloat(_ value: Any?) -> CGFloat? {
        if let value = value as? CGFloat { return value }
        if let value = value as? Double { return CGFloat(value) }
        if let value = value as? Int { return CGFloat(value) }
        if let value = value as? NSNumber { return CGFloat(value.doubleValue) }
        return nil
    }
}

final class StreamContextMosaicSemanticSnapshotCache: @unchecked Sendable {
    private struct CacheKey: Equatable {
        let logicalSize: MiragePixelSize
        let captureBounds: CGRect
    }

    private struct State {
        var key: CacheKey?
        var snapshot = StreamContextMosaicSemanticSnapshot(candidates: [], isTransientSystemState: false)
        var lastRefreshTime: CFAbsoluteTime = 0
        var refreshInFlight = false
    }

    private let provider: any StreamContextMosaicSemanticObservationProviding
    private let builder = StreamContextMosaicSemanticSnapshotBuilder()
    private let refreshInterval: CFAbsoluteTime
    private let lock = NSLock()
    private var state = State()

    init(
        provider: any StreamContextMosaicSemanticObservationProviding = MacOSMosaicSemanticObservationProvider(),
        refreshInterval: CFAbsoluteTime = 0.25
    ) {
        self.provider = provider
        self.refreshInterval = refreshInterval
    }

    func snapshot(
        logicalSize: MiragePixelSize,
        captureBounds: CGRect,
        now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    ) -> StreamContextMosaicSemanticSnapshot {
        let key = CacheKey(logicalSize: logicalSize, captureBounds: captureBounds.standardized)
        let cached: StreamContextMosaicSemanticSnapshot
        let shouldRefresh: Bool
        lock.lock()
        cached = state.key == key ? state.snapshot : StreamContextMosaicSemanticSnapshot(
            candidates: [],
            isTransientSystemState: false
        )
        shouldRefresh = !state.refreshInFlight &&
            (state.key != key || now - state.lastRefreshTime >= refreshInterval)
        if shouldRefresh {
            state.refreshInFlight = true
        }
        lock.unlock()

        if shouldRefresh {
            Task.detached(priority: .utility) { [weak self] in
                self?.refresh(key: key)
            }
        }
        return cached
    }

    func reset() {
        lock.lock()
        state = State()
        lock.unlock()
    }

    private func refresh(key: CacheKey) {
        let observations = provider.observations()
        let snapshot = builder.snapshot(
            logicalSize: key.logicalSize,
            captureBounds: key.captureBounds,
            windows: observations
        )
        lock.lock()
        state.key = key
        state.snapshot = snapshot
        state.lastRefreshTime = CFAbsoluteTimeGetCurrent()
        state.refreshInFlight = false
        lock.unlock()
    }
}

#endif
