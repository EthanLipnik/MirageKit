//
//  StreamContextMosaicSemanticSnapshotter.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 6/6/26.
//

import CoreGraphics
import Foundation
import MirageCore
import MirageDiagnostics
import MirageKit
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
    let subrole: String?
    let title: String?
    let roleDescription: String?
    let depth: Int
    let isFocused: Bool

    init(
        id: String,
        role: String,
        frame: CGRect,
        subrole: String? = nil,
        title: String? = nil,
        roleDescription: String? = nil,
        depth: Int = 0,
        isFocused: Bool = false
    ) {
        self.id = id
        self.role = role
        self.frame = frame
        self.subrole = subrole
        self.title = title
        self.roleDescription = roleDescription
        self.depth = depth
        self.isFocused = isFocused
    }
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
        let hasFocusedContentWindow = visibleWindows.contains {
            ($0.isFocused || $0.isMain) && isContentWindow($0)
        }
        var isTransientSystemState = false

        for window in visibleWindows {
            guard let windowRect = pixelRect(
                window.frame,
                logicalSize: logicalSize,
                captureBounds: captureBounds
            ) else {
                continue
            }
            let windowTileID = MirageMosaicTileID(rawValue: "window-\(window.windowID)")
            if isTransientSystemWindow(window, windowRect: windowRect, logicalSize: logicalSize) {
                isTransientSystemState = true
            }

            if let chromeClass = semanticClass(
                forSystemWindow: window,
                windowRect: windowRect,
                logicalSize: logicalSize
            ) {
                candidates.append(StreamContextMosaicSemanticCandidate(
                    id: MirageMosaicTileID(rawValue: "\(chromeClass.rawValue)-window-\(window.windowID)"),
                    rect: windowRect,
                    semanticClass: chromeClass,
                    priority: priority(for: chromeClass, parentWindow: window),
                    codecStrategy: codecStrategy(),
                    commitPolicy: commitPolicy(for: chromeClass),
                    isReliable: true
                ))
            }

            guard isContentWindow(window),
                  !hasFocusedContentWindow || window.isFocused || window.isMain else {
                continue
            }
            for child in window.children {
                guard let childRect = pixelRect(
                        child.frame,
                        logicalSize: logicalSize,
                        captureBounds: captureBounds
                      ),
                      let childClass = semanticClass(
                        for: child,
                        childRect: childRect,
                        parentWindowRect: windowRect
                      ) else {
                    continue
                }
                candidates.append(StreamContextMosaicSemanticCandidate(
                    id: tileID(
                        for: child,
                        semanticClass: childClass,
                        rect: childRect,
                        windowID: window.windowID
                    ),
                    rect: childRect,
                    semanticClass: childClass,
                    priority: priority(for: childClass, parentWindow: window),
                    parentID: windowTileID,
                    codecStrategy: codecStrategy(),
                    commitPolicy: commitPolicy(for: childClass),
                    isReliable: true
                ))
            }
        }

        return StreamContextMosaicSemanticSnapshot(
            candidates: normalizedCandidates(candidates),
            isTransientSystemState: isTransientSystemState
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

    func semanticClass(forAXRole role: String) -> MirageMosaicSemanticClass? {
        switch role {
        case "AXScrollArea":
            .scrollView
        case "AXTextArea":
            .textViewport
        case "AXTable",
             "AXOutline",
             "AXList",
             "AXBrowser":
            .scrollView
        case "AXToolbar":
            .toolbar
        case "AXMenuBar":
            .menuBar
        case "AXMenu":
            .menu
        default:
            nil
        }
    }

    private func semanticClass(
        for child: StreamContextMosaicSemanticElementObservation,
        childRect: MiragePixelRect,
        parentWindowRect: MiragePixelRect
    ) -> MirageMosaicSemanticClass? {
        switch child.role {
        case "AXScrollArea":
            if isSidebar(childRect, in: parentWindowRect) {
                return .sidebar
            }
            return .scrollView
        case "AXTable",
             "AXOutline",
             "AXList",
             "AXBrowser":
            if isSidebar(childRect, in: parentWindowRect) {
                return .sidebar
            }
            return .scrollView
        case "AXTextArea":
            return .textViewport
        case "AXTextField":
            return nil
        case "AXToolbar":
            return .toolbar
        case "AXMenuBar":
            return .menuBar
        case "AXMenu":
            return .menu
        default:
            return semanticClass(forAXRole: child.role)
        }
    }

    private func semanticClass(
        forSystemWindow window: StreamContextMosaicSemanticWindowObservation,
        windowRect: MiragePixelRect,
        logicalSize: MiragePixelSize
    ) -> MirageMosaicSemanticClass? {
        guard !isTransientSystemWindow(window, windowRect: windowRect, logicalSize: logicalSize) else { return nil }
        if window.ownerName == "Dock", isDock(windowRect, in: logicalSize) {
            return .dock
        }
        if isMenuBar(window, windowRect: windowRect, logicalSize: logicalSize) {
            return .menuBar
        }
        return nil
    }

    private func isSidebar(_ rect: MiragePixelRect, in parent: MiragePixelRect) -> Bool {
        guard parent.width > 0, parent.height > 0 else { return false }
        let maxSidebarWidth = max(160, parent.width * 38 / 100)
        let minSidebarHeight = max(120, parent.height / 3)
        let edgeTolerance = max(24, parent.width / 25)
        let touchesLeadingEdge = rect.x <= parent.x + edgeTolerance
        let touchesTrailingEdge = rect.x + rect.width >= parent.x + parent.width - edgeTolerance
        return rect.width <= maxSidebarWidth &&
            rect.height >= minSidebarHeight &&
            (touchesLeadingEdge || touchesTrailingEdge)
    }

    private func isDock(_ rect: MiragePixelRect, in logicalSize: MiragePixelSize) -> Bool {
        guard !logicalSize.isEmpty else { return false }
        let maxThickness = max(80, min(logicalSize.width, logicalSize.height) / 4)
        let edgeTolerance = 12
        let touchesHorizontalEdge = rect.y <= edgeTolerance ||
            rect.y + rect.height >= logicalSize.height - edgeTolerance
        let touchesVerticalEdge = rect.x <= edgeTolerance ||
            rect.x + rect.width >= logicalSize.width - edgeTolerance
        let isStrip = rect.height <= maxThickness || rect.width <= maxThickness
        return isStrip &&
            (touchesHorizontalEdge || touchesVerticalEdge) &&
            rect.width >= 48 &&
            rect.height >= 48
    }

    private func isMenuBar(
        _ window: StreamContextMosaicSemanticWindowObservation,
        windowRect: MiragePixelRect,
        logicalSize: MiragePixelSize
    ) -> Bool {
        guard window.ownerName == "SystemUIServer" || window.ownerName == "Window Server" else {
            return false
        }
        let maxHeight = max(24, logicalSize.height / 18)
        return windowRect.y <= 8 &&
            windowRect.width >= logicalSize.width * 2 / 3 &&
            windowRect.height >= 12 &&
            windowRect.height <= maxHeight
    }

    private func isContentWindow(_ window: StreamContextMosaicSemanticWindowObservation) -> Bool {
        guard window.layer == 0 else { return false }
        return switch window.ownerName {
        case "Control Center",
             "Dock",
             "loginwindow",
             "SystemUIServer",
             "Window Server",
             "WindowManager":
            false
        default:
            true
        }
    }

    private func priority(
        for semanticClass: MirageMosaicSemanticClass,
        parentWindow: StreamContextMosaicSemanticWindowObservation
    ) -> MirageMosaicTilePriority {
        switch semanticClass {
        case .scrollView,
             .textViewport,
             .sidebar:
            parentWindow.isFocused || parentWindow.isMain ? .focusedContent : .semanticContent
        case .menuBar,
             .dock,
             .toolbar,
             .chromeAtlas,
             .popover,
             .sheet,
             .menu:
            .transientChrome
        default:
            .semanticContent
        }
    }

    private func codecStrategy() -> MirageMosaicCodecStrategy {
        .singleUnit
    }

    private func tileID(
        for child: StreamContextMosaicSemanticElementObservation,
        semanticClass: MirageMosaicSemanticClass,
        rect: MiragePixelRect,
        windowID: WindowID
    ) -> MirageMosaicTileID {
        if !Self.isGeneratedObservationID(child.id) {
            return MirageMosaicTileID(rawValue: "window-\(windowID)-\(child.id)")
        }

        let rectKey = Self.quantizedRectKey(rect)
        return MirageMosaicTileID(rawValue: [
            "window-\(windowID)",
            semanticClass.rawValue,
            child.role,
            rectKey
        ].joined(separator: "-"))
    }

    private func commitPolicy(for semanticClass: MirageMosaicSemanticClass) -> MirageMosaicCommitPolicy {
        switch semanticClass {
        case .scrollView,
             .textViewport,
             .sidebar:
            .atomic
        default:
            .independent
        }
    }

    private func isTransientSystemWindow(
        _ window: StreamContextMosaicSemanticWindowObservation,
        windowRect: MiragePixelRect,
        logicalSize: MiragePixelSize
    ) -> Bool {
        guard window.ownerName == "Dock" else { return false }
        let windowArea = windowRect.width * windowRect.height
        let displayArea = max(1, logicalSize.width * logicalSize.height)
        return window.layer > 10 &&
            Double(windowArea) / Double(displayArea) > 0.75
    }

    private func normalizedCandidates(
        _ candidates: [StreamContextMosaicSemanticCandidate]
    ) -> [StreamContextMosaicSemanticCandidate] {
        let usefulCandidates = candidates.filter(isUsefulCandidate)
        let sortedCandidates = usefulCandidates.sorted(by: Self.normalizationOrder)
        var normalized: [StreamContextMosaicSemanticCandidate] = []
        normalized.reserveCapacity(min(sortedCandidates.count, 16))

        for candidate in sortedCandidates {
            if isBroadContainer(candidate, coveredBy: sortedCandidates) {
                continue
            }
            if normalized.contains(where: { Self.isDuplicate(candidate, of: $0) }) {
                continue
            }
            normalized.append(candidate)
            if normalized.count == 16 { break }
        }
        return normalized
    }

    private func isUsefulCandidate(_ candidate: StreamContextMosaicSemanticCandidate) -> Bool {
        switch candidate.semanticClass {
        case .scrollView:
            return candidate.rect.width >= 160 &&
                candidate.rect.height >= 120 &&
                candidate.rect.width * candidate.rect.height >= 30_000
        case .textViewport:
            return candidate.rect.width >= 320 &&
                candidate.rect.height >= 160 &&
                candidate.rect.width * candidate.rect.height >= 80_000
        case .sidebar:
            return candidate.rect.width >= 80 &&
                candidate.rect.height >= 120 &&
                candidate.rect.width * candidate.rect.height >= 12_000
        case .toolbar:
            return candidate.rect.width >= 128 &&
                candidate.rect.height >= 24
        case .menuBar:
            return candidate.rect.width >= 256 &&
                candidate.rect.height >= 12 &&
                candidate.rect.height <= 96
        case .dock:
            return candidate.rect.width >= 48 &&
                candidate.rect.height >= 48
        case .popover,
             .sheet,
             .menu:
            return candidate.rect.width >= 96 &&
                candidate.rect.height >= 48
        default:
            return false
        }
    }

    private func isBroadContainer(
        _ candidate: StreamContextMosaicSemanticCandidate,
        coveredBy candidates: [StreamContextMosaicSemanticCandidate]
    ) -> Bool {
        guard candidate.semanticClass == .scrollView else { return false }
        return candidates.contains { other in
            other.id != candidate.id &&
                isPaneClass(other.semanticClass) &&
                Self.contains(candidate.rect, other.rect) &&
                Self.coverageRatio(candidate.rect, coveredBy: other.rect) > 0.65
        }
    }

    private func isPaneClass(_ semanticClass: MirageMosaicSemanticClass) -> Bool {
        switch semanticClass {
        case .scrollView,
             .textViewport,
             .sidebar:
            true
        default:
            false
        }
    }

    private static func normalizationOrder(
        lhs: StreamContextMosaicSemanticCandidate,
        rhs: StreamContextMosaicSemanticCandidate
    ) -> Bool {
        if lhs.parentID == rhs.id { return true }
        if rhs.parentID == lhs.id { return false }
        if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
        let lhsRank = semanticRank(lhs.semanticClass)
        let rhsRank = semanticRank(rhs.semanticClass)
        if lhsRank != rhsRank { return lhsRank < rhsRank }
        let lhsArea = lhs.rect.width * lhs.rect.height
        let rhsArea = rhs.rect.width * rhs.rect.height
        if lhsArea != rhsArea { return lhsArea > rhsArea }
        return lhs.id < rhs.id
    }

    private static func semanticRank(_ semanticClass: MirageMosaicSemanticClass) -> Int {
        switch semanticClass {
        case .textViewport:
            0
        case .scrollView:
            1
        case .sidebar:
            2
        case .toolbar:
            3
        case .menuBar,
             .dock,
             .chromeAtlas:
            4
        case .popover,
             .sheet,
             .menu:
            5
        default:
            6
        }
    }

    private static func isDuplicate(
        _ candidate: StreamContextMosaicSemanticCandidate,
        of existing: StreamContextMosaicSemanticCandidate
    ) -> Bool {
        guard candidate.semanticClass == existing.semanticClass ||
              isPaneLike(candidate.semanticClass) && isPaneLike(existing.semanticClass) else {
            return false
        }
        return overlapRatio(candidate.rect, existing.rect) > 0.86
    }

    private static func isPaneLike(_ semanticClass: MirageMosaicSemanticClass) -> Bool {
        switch semanticClass {
        case .scrollView,
             .textViewport,
             .sidebar:
            true
        default:
            false
        }
    }

    private static func isGeneratedObservationID(_ id: String) -> Bool {
        guard let firstDash = id.firstIndex(of: "-") else { return false }
        return id[..<firstDash].allSatisfy(\.isNumber)
    }

    private static func quantizedRectKey(_ rect: MiragePixelRect, bucketSize: Int = 16) -> String {
        [
            quantized(rect.x, bucketSize: bucketSize),
            quantized(rect.y, bucketSize: bucketSize),
            quantized(rect.width, bucketSize: bucketSize),
            quantized(rect.height, bucketSize: bucketSize),
        ]
        .map(String.init)
        .joined(separator: "x")
    }

    private static func quantized(_ value: Int, bucketSize: Int) -> Int {
        guard bucketSize > 1 else { return value }
        return ((value + bucketSize / 2) / bucketSize) * bucketSize
    }

    private static func contains(_ outer: MiragePixelRect, _ inner: MiragePixelRect) -> Bool {
        inner.x >= outer.x &&
            inner.y >= outer.y &&
            inner.x + inner.width <= outer.x + outer.width &&
            inner.y + inner.height <= outer.y + outer.height
    }

    private static func overlapRatio(_ lhs: MiragePixelRect, _ rhs: MiragePixelRect) -> Double {
        guard let intersection = intersection(lhs, rhs) else { return 0 }
        let intersectionArea = intersection.width * intersection.height
        let smallerArea = max(1, min(lhs.width * lhs.height, rhs.width * rhs.height))
        return Double(intersectionArea) / Double(smallerArea)
    }

    private static func coverageRatio(_ rect: MiragePixelRect, coveredBy other: MiragePixelRect) -> Double {
        guard let intersection = intersection(rect, other) else { return 0 }
        let intersectionArea = intersection.width * intersection.height
        let rectArea = max(1, rect.width * rect.height)
        return Double(intersectionArea) / Double(rectArea)
    }

    private static func intersection(_ lhs: MiragePixelRect, _ rhs: MiragePixelRect) -> MiragePixelRect? {
        let minX = max(lhs.x, rhs.x)
        let minY = max(lhs.y, rhs.y)
        let maxX = min(lhs.x + lhs.width, rhs.x + rhs.width)
        let maxY = min(lhs.y + lhs.height, rhs.y + rhs.height)
        guard maxX > minX, maxY > minY else { return nil }
        return MiragePixelRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
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
        var queue = (HostAccessibilityWindowLookup.elementArrayAttributeValue(
            root,
            attribute: kAXChildrenAttribute as CFString
        ) ?? []).map { (element: $0, depth: 1) }
        var visitedCount = 0
        var visitedElements = Set<UInt>()
        while let item = queue.first, visitedCount < 384 {
            queue.removeFirst()
            let element = item.element
            let identity = UInt(bitPattern: Unmanaged.passUnretained(element).toOpaque())
            guard visitedElements.insert(identity).inserted else { continue }
            visitedCount += 1
            let role = HostAccessibilityWindowLookup.stringAttribute(kAXRoleAttribute as CFString, from: element) ?? ""
            if let frame = HostAccessibilityWindowLookup.frame(of: element),
               StreamContextMosaicSemanticSnapshotBuilder().semanticClass(forAXRole: role) != nil {
                observations.append(StreamContextMosaicSemanticElementObservation(
                    id: "\(observations.count)-\(role)",
                    role: role,
                    frame: frame,
                    subrole: HostAccessibilityWindowLookup.stringAttribute(kAXSubroleAttribute as CFString, from: element),
                    title: HostAccessibilityWindowLookup.stringAttribute(kAXTitleAttribute as CFString, from: element),
                    roleDescription: HostAccessibilityWindowLookup.stringAttribute(
                        kAXRoleDescriptionAttribute as CFString,
                        from: element
                    ),
                    depth: item.depth,
                    isFocused: HostAccessibilityWindowLookup.boolAttribute(kAXFocusedAttribute as CFString, from: element) ?? false
                ))
            }
            if observations.count < 96 {
                for descendant in semanticDescendants(of: element) {
                    queue.append(contentsOf: descendant.prefix(32).map { (element: $0, depth: item.depth + 1) })
                }
            }
        }
        return observations
    }

    private static func semanticDescendants(of element: AXUIElement) -> [[AXUIElement]] {
        [
            kAXChildrenAttribute as CFString,
            kAXContentsAttribute as CFString,
            "AXRows" as CFString,
            "AXVisibleRows" as CFString,
            "AXColumns" as CFString,
            "AXTabs" as CFString,
        ].compactMap { attribute in
            HostAccessibilityWindowLookup.elementArrayAttributeValue(element, attribute: attribute)
        }
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
        var lastDiagnosticLogTime: CFAbsoluteTime = 0
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
        let shouldRefreshSynchronously: Bool
        let shouldRefresh: Bool
        lock.lock()
        cached = state.key == key ? state.snapshot : StreamContextMosaicSemanticSnapshot(
            candidates: [],
            isTransientSystemState: false
        )
        shouldRefreshSynchronously = state.key != key
        shouldRefresh = !state.refreshInFlight &&
            (state.key != key || now - state.lastRefreshTime >= refreshInterval)
        if shouldRefresh {
            state.refreshInFlight = true
        }
        lock.unlock()

        if shouldRefreshSynchronously {
            return refresh(key: key)
        }
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

    @discardableResult
    private func refresh(key: CacheKey) -> StreamContextMosaicSemanticSnapshot {
        let observations = provider.observations()
        let snapshot = builder.snapshot(
            logicalSize: key.logicalSize,
            captureBounds: key.captureBounds,
            windows: observations
        )
        let refreshedAt = CFAbsoluteTimeGetCurrent()
        let shouldLogDiagnostics: Bool
        lock.lock()
        state.key = key
        state.snapshot = snapshot
        state.lastRefreshTime = refreshedAt
        state.refreshInFlight = false
        if MirageLogger.isEnabled(.metrics),
           refreshedAt - state.lastDiagnosticLogTime >= 1.0 {
            state.lastDiagnosticLogTime = refreshedAt
            shouldLogDiagnostics = true
        } else {
            shouldLogDiagnostics = false
        }
        lock.unlock()

        if shouldLogDiagnostics {
            let bounds = key.captureBounds
            let candidateSummary = snapshot.candidates.prefix(3).map { candidate in
                "\(candidate.id.rawValue):\(candidate.semanticClass.rawValue)@\(candidate.rect.x),\(candidate.rect.y),\(candidate.rect.width),\(candidate.rect.height)"
            }.joined(separator: ";")
            MirageLogger.metrics(
                "Mosaic semantic snapshot: observations=\(observations.count) " +
                    "candidates=\(snapshot.candidates.count) transient=\(snapshot.isTransientSystemState) " +
                    "bounds=(\(Int(bounds.minX)),\(Int(bounds.minY)),\(Int(bounds.width)),\(Int(bounds.height))) " +
                    "logical=\(key.logicalSize.width)x\(key.logicalSize.height) " +
                    "accessibilityTrusted=\(AXIsProcessTrusted()) sample=[\(candidateSummary)]"
            )
        }
        return snapshot
    }
}

#endif
