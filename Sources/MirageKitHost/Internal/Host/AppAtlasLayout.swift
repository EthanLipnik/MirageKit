//
//  AppAtlasLayout.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/2/26.
//

import CoreGraphics
import MirageKit

#if os(macOS)
/// Packs multiple logical app windows into one encoder-aligned app-atlas video surface.
enum AppAtlasLayout {
    /// Input window geometry for app-atlas packing.
    struct Window: Identifiable, Equatable {
        /// Host window identifier represented by this logical atlas window.
        let id: WindowID
        /// Source rectangle in the captured window surface.
        let sourceRect: CGRect

        init(id: WindowID, sourceRect: CGRect) {
            self.id = id
            self.sourceRect = sourceRect.standardized
        }

        /// Whether the source rectangle can produce a non-empty encoded region.
        var isValid: Bool {
            sourceRect.width > 0 &&
                sourceRect.height > 0 &&
                sourceRect.width.isFinite &&
                sourceRect.height.isFinite
        }
    }

    /// Mapping from one source window rectangle into the atlas canvas.
    struct Placement: Identifiable, Equatable {
        /// Host window identifier placed in the atlas.
        let id: WindowID
        /// Window-local source rectangle copied into the atlas.
        let sourceRect: CGRect
        /// Atlas-local destination rectangle occupied by the source.
        let destinationRect: CGRect
    }

    /// Packed atlas canvas and its per-window placements.
    struct Result: Equatable {
        /// Encoder-aligned pixel size of the atlas canvas.
        let canvasSize: CGSize
        /// Ordered window placements inside the atlas.
        let placements: [Placement]

        /// Converts the internal placement result into the wire-layout message sent to clients.
        func makePublicLayout(
            mediaStreamID: StreamID,
            layoutEpoch: UInt64,
            focusedWindowID: WindowID? = nil
        ) -> MirageAppAtlasLayout {
            MirageAppAtlasLayout(
                mediaStreamID: mediaStreamID,
                layoutEpoch: layoutEpoch,
                width: Int(canvasSize.width),
                height: Int(canvasSize.height),
                regions: placements.enumerated().map { index, placement in
                    MirageAppAtlasRegion(
                        windowID: placement.id,
                        x: Int(placement.destinationRect.minX),
                        y: Int(placement.destinationRect.minY),
                        width: Int(placement.destinationRect.width),
                        height: Int(placement.destinationRect.height),
                        zIndex: index,
                        isFocused: placement.id == focusedWindowID,
                        isVisible: true
                    )
                }
            )
        }
    }

    private struct NativeCandidate {
        let result: Result
        let area: CGFloat
        let aspectPenalty: CGFloat
    }

    private static let maxExhaustiveWindowCount = 10
    private static let maxFallbackRows = 6

    /// Builds a native-resolution atlas layout without scaling individual windows.
    static func nativePackedLayout(
        windows: [Window],
        spacing requestedSpacing: CGFloat = 0
    ) -> Result {
        let validWindows = windows.filter(\.isValid)
        guard !validWindows.isEmpty else {
            return Result(canvasSize: .zero, placements: [])
        }

        if validWindows.count == 1, let window = validWindows.first {
            let size = evenSize(window.sourceRect.size)
            let canvasSize = encoderAlignedCanvasSize(size)
            let destinationRect = CGRect(origin: .zero, size: size)
            let placement = Placement(
                id: window.id,
                sourceRect: CGRect(origin: window.sourceRect.origin, size: size),
                destinationRect: destinationRect
            )
            return Result(canvasSize: canvasSize, placements: [placement])
        }

        let spacing = normalizedSpacing(requestedSpacing)
        let candidates = rowPartitions(for: validWindows).compactMap { rows in
            nativeLayoutCandidate(rows: rows, spacing: spacing)
        }

        guard let best = candidates.min(by: isHigherNativePriority(_:than:)) else {
            return Result(canvasSize: .zero, placements: [])
        }

        return best.result
    }

    /// Builds one candidate layout for a specific partition of windows into rows.
    private static func nativeLayoutCandidate(
        rows: [[Window]],
        spacing: CGFloat
    ) -> NativeCandidate? {
        guard !rows.isEmpty else { return nil }

        var rowLayouts: [(windows: [Window], sizes: [CGSize], width: CGFloat, height: CGFloat)] = []
        rowLayouts.reserveCapacity(rows.count)

        for row in rows {
            let sizes = row.map { evenSize($0.sourceRect.size) }
            guard sizes.allSatisfy({ $0.width > 0 && $0.height > 0 }) else { return nil }
            let rowWidth = sizes.reduce(CGFloat.zero) { $0 + $1.width } +
                spacing * CGFloat(max(0, sizes.count - 1))
            let rowHeight = sizes.map(\.height).max() ?? 0
            guard rowWidth > 0, rowHeight > 0 else { return nil }
            rowLayouts.append((row, sizes, rowWidth, rowHeight))
        }

        let contentWidth = evenLength(rowLayouts.map(\.width).max() ?? 0)
        let contentHeight = evenLength(
            rowLayouts.reduce(CGFloat.zero) { $0 + $1.height } +
                spacing * CGFloat(max(0, rowLayouts.count - 1))
        )
        let canvasSize = encoderAlignedCanvasSize(CGSize(width: contentWidth, height: contentHeight))
        guard contentWidth > 0, contentHeight > 0 else { return nil }

        var placements: [Placement] = []
        placements.reserveCapacity(rows.reduce(0) { $0 + $1.count })

        var y: CGFloat = 0
        for rowLayout in rowLayouts {
            var x: CGFloat = 0
            for (index, window) in rowLayout.windows.enumerated() {
                let size = rowLayout.sizes[index]
                let destinationRect = CGRect(x: x, y: y, width: size.width, height: size.height)
                placements.append(
                    Placement(
                        id: window.id,
                        sourceRect: CGRect(origin: window.sourceRect.origin, size: size),
                        destinationRect: destinationRect
                    )
                )
                x += size.width + spacing
            }
            y += rowLayout.height + spacing
        }

        let result = Result(
            canvasSize: canvasSize,
            placements: placements
        )
        let area = canvasSize.width * canvasSize.height
        let aspectRatio = canvasSize.height > 0 ? canvasSize.width / canvasSize.height : 1
        return NativeCandidate(
            result: result,
            area: area,
            aspectPenalty: abs(aspectRatio - 16.0 / 10.0)
        )
    }

    /// Returns candidate row partitions for exhaustive search or balanced fallback.
    private static func rowPartitions(for windows: [Window]) -> [[[Window]]] {
        guard !windows.isEmpty else { return [] }
        guard windows.count > 1 else { return [[windows]] }

        if windows.count <= maxExhaustiveWindowCount {
            let splitCount = windows.count - 1
            let maskCount = 1 << splitCount
            return (0 ..< maskCount).map { mask in
                var rows: [[Window]] = []
                var currentRow: [Window] = []
                for index in windows.indices {
                    currentRow.append(windows[index])
                    let shouldSplit = index == windows.count - 1 || (mask & (1 << index)) != 0
                    if shouldSplit {
                        rows.append(currentRow)
                        currentRow = []
                    }
                }
                return rows
            }
        }

        let rowLimit = min(windows.count, maxFallbackRows)
        return (1 ... rowLimit).map { rowCount in
            balancedPartition(windows: windows, rowCount: rowCount)
        }
    }

    /// Splits a large window list into roughly even rows for fallback layout search.
    private static func balancedPartition(windows: [Window], rowCount: Int) -> [[Window]] {
        guard rowCount > 1 else { return [windows] }

        var rows: [[Window]] = []
        rows.reserveCapacity(rowCount)
        var cursor = 0
        for rowIndex in 0 ..< rowCount {
            let remainingWindows = windows.count - cursor
            let remainingRows = rowCount - rowIndex
            let rowSize = max(1, Int(ceil(Double(remainingWindows) / Double(remainingRows))))
            let upperBound = min(windows.count, cursor + rowSize)
            rows.append(Array(windows[cursor ..< upperBound]))
            cursor = upperBound
        }
        return rows
    }

    /// Ranks native layout candidates by canvas area, aspect ratio, then retained placements.
    private static func isHigherNativePriority(_ lhs: NativeCandidate, than rhs: NativeCandidate) -> Bool {
        let areaDelta = lhs.area - rhs.area
        if abs(areaDelta) > 0.5 {
            return lhs.area < rhs.area
        }

        let aspectDelta = lhs.aspectPenalty - rhs.aspectPenalty
        if abs(aspectDelta) > 0.0001 {
            return lhs.aspectPenalty < rhs.aspectPenalty
        }

        return lhs.result.placements.count > rhs.result.placements.count
    }

    /// Normalizes requested spacing to a non-negative whole-pixel value.
    private static func normalizedSpacing(_ spacing: CGFloat) -> CGFloat {
        guard spacing.isFinite, spacing > 0 else { return 0 }
        return floor(spacing)
    }

    /// Returns an even pixel size for encoder-friendly source copies.
    private static func evenSize(_ size: CGSize) -> CGSize {
        CGSize(width: evenLength(size.width), height: evenLength(size.height))
    }

    /// Rounds a length down to the nearest even positive pixel count.
    private static func evenLength(_ value: CGFloat) -> CGFloat {
        guard value.isFinite, value > 0 else { return 0 }
        let rounded = Int(value.rounded())
        let even = rounded - (rounded % 2)
        return CGFloat(max(2, even))
    }

    /// Aligns an atlas canvas size to encoder macroblock boundaries.
    private static func encoderAlignedCanvasSize(_ size: CGSize) -> CGSize {
        CGSize(
            width: encoderAlignedCanvasLength(size.width),
            height: encoderAlignedCanvasLength(size.height)
        )
    }

    /// Aligns a canvas dimension up to a 16-pixel boundary.
    private static func encoderAlignedCanvasLength(_ value: CGFloat) -> CGFloat {
        guard value.isFinite, value > 0 else { return 0 }
        let rounded = max(1, Int(ceil(value)))
        let aligned = ((rounded + 15) / 16) * 16
        return CGFloat(max(16, aligned))
    }
}
#endif
