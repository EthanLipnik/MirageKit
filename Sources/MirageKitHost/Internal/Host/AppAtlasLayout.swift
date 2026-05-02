//
//  AppAtlasLayout.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/2/26.
//

import CoreGraphics
import MirageKit

#if os(macOS)
enum AppAtlasLayout {
    struct Window: Identifiable, Sendable, Equatable {
        let id: WindowID
        let sourceRect: CGRect

        init(id: WindowID, sourceRect: CGRect) {
            self.id = id
            self.sourceRect = sourceRect.standardized
        }

        var aspectRatio: CGFloat {
            let size = sourceRect.size
            guard size.width > 0, size.height > 0 else { return 1 }
            let ratio = size.width / size.height
            return ratio.isFinite && ratio > 0 ? ratio : 1
        }

        var isValid: Bool {
            sourceRect.width > 0 &&
                sourceRect.height > 0 &&
                sourceRect.width.isFinite &&
                sourceRect.height.isFinite
        }
    }

    struct Placement: Identifiable, Sendable, Equatable {
        let id: WindowID
        let sourceRect: CGRect
        let destinationRect: CGRect
        let normalizedDestinationRect: CGRect

        var windowID: WindowID { id }

        func sourcePoint(forCanvasPoint point: CGPoint) -> CGPoint? {
            guard destinationRect.width > 0,
                  destinationRect.height > 0,
                  sourceRect.width > 0,
                  sourceRect.height > 0,
                  destinationRect.contains(point) else {
                return nil
            }

            let normalizedX = (point.x - destinationRect.minX) / destinationRect.width
            let normalizedY = (point.y - destinationRect.minY) / destinationRect.height
            return CGPoint(
                x: sourceRect.minX + normalizedX * sourceRect.width,
                y: sourceRect.minY + normalizedY * sourceRect.height
            )
        }
    }

    struct Result: Sendable, Equatable {
        let canvasSize: CGSize
        let contentRect: CGRect
        let placements: [Placement]

        var isEmpty: Bool { placements.isEmpty }

        func placement(containing point: CGPoint) -> Placement? {
            placements.first { $0.destinationRect.contains(point) }
        }

        func sourcePoint(forCanvasPoint point: CGPoint) -> (windowID: WindowID, point: CGPoint)? {
            guard let placement = placement(containing: point),
                  let sourcePoint = placement.sourcePoint(forCanvasPoint: point) else {
                return nil
            }
            return (placement.windowID, sourcePoint)
        }

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
                        windowID: placement.windowID,
                        x: Int(placement.destinationRect.minX),
                        y: Int(placement.destinationRect.minY),
                        width: Int(placement.destinationRect.width),
                        height: Int(placement.destinationRect.height),
                        zIndex: index,
                        isFocused: placement.windowID == focusedWindowID,
                        isVisible: true
                    )
                }
            )
        }
    }

    private struct Candidate: Sendable {
        let result: Result
        let usedArea: CGFloat
        let rowCount: Int
    }

    private static let maxExhaustiveWindowCount = 10
    private static let maxFallbackRows = 6

    static func fixedCanvasLayout(
        windows: [Window],
        canvasSize: CGSize,
        spacing requestedSpacing: CGFloat = 0
    ) -> Result {
        let resolvedCanvasSize = normalizedCanvasSize(canvasSize)
        guard resolvedCanvasSize.width > 0, resolvedCanvasSize.height > 0 else {
            return Result(canvasSize: .zero, contentRect: .zero, placements: [])
        }

        let validWindows = windows.filter(\.isValid)
        guard !validWindows.isEmpty else {
            return Result(canvasSize: resolvedCanvasSize, contentRect: .zero, placements: [])
        }

        let spacing = normalizedSpacing(requestedSpacing)
        let candidates = rowPartitions(for: validWindows).compactMap { rows in
            layoutCandidate(
                rows: rows,
                canvasSize: resolvedCanvasSize,
                spacing: spacing
            )
        }

        guard let best = candidates.max(by: isLowerPriority(_:than:)) else {
            return Result(canvasSize: resolvedCanvasSize, contentRect: .zero, placements: [])
        }

        return best.result
    }

    static func aspectFittedRect(
        sourceSize: CGSize,
        in bounds: CGRect
    ) -> CGRect {
        let normalizedBounds = bounds.standardized
        guard sourceSize.width > 0,
              sourceSize.height > 0,
              normalizedBounds.width > 0,
              normalizedBounds.height > 0 else {
            return normalizedBounds
        }

        let sourceAspectRatio = sourceSize.width / sourceSize.height
        guard sourceAspectRatio.isFinite, sourceAspectRatio > 0 else {
            return normalizedBounds
        }

        let boundsAspectRatio = normalizedBounds.width / normalizedBounds.height
        let fittedSize: CGSize
        if boundsAspectRatio > sourceAspectRatio {
            fittedSize = CGSize(
                width: floor(normalizedBounds.height * sourceAspectRatio),
                height: normalizedBounds.height
            )
        } else {
            fittedSize = CGSize(
                width: normalizedBounds.width,
                height: floor(normalizedBounds.width / sourceAspectRatio)
            )
        }

        return CGRect(
            x: normalizedBounds.minX + floor((normalizedBounds.width - fittedSize.width) * 0.5),
            y: normalizedBounds.minY + floor((normalizedBounds.height - fittedSize.height) * 0.5),
            width: max(1, fittedSize.width),
            height: max(1, fittedSize.height)
        )
    }

    private static func layoutCandidate(
        rows: [[Window]],
        canvasSize: CGSize,
        spacing: CGFloat
    ) -> Candidate? {
        guard !rows.isEmpty else { return nil }

        let verticalSpacing = resolvedSpacing(
            spacing,
            itemCount: rows.count,
            availableLength: canvasSize.height
        )
        let availableRowHeight = canvasSize.height - verticalSpacing * CGFloat(max(0, rows.count - 1))
        guard availableRowHeight > 0 else { return nil }

        let naturalRowHeights = rows.map { row -> CGFloat in
            let horizontalSpacing = resolvedSpacing(
                spacing,
                itemCount: row.count,
                availableLength: canvasSize.width
            )
            let availableRowWidth = canvasSize.width - horizontalSpacing * CGFloat(max(0, row.count - 1))
            let rowAspect = row.reduce(CGFloat.zero) { $0 + $1.aspectRatio }
            guard availableRowWidth > 0, rowAspect > 0 else { return 0 }
            return availableRowWidth / rowAspect
        }
        let naturalHeight = naturalRowHeights.reduce(CGFloat.zero, +)
        guard naturalHeight > 0 else { return nil }

        let scale = min(1, availableRowHeight / naturalHeight)
        guard scale.isFinite, scale > 0 else { return nil }

        var rowLayouts: [(windows: [Window], height: CGFloat, widths: [CGFloat], spacing: CGFloat, width: CGFloat)] = []
        rowLayouts.reserveCapacity(rows.count)

        for (rowIndex, row) in rows.enumerated() {
            let rowHeight = floor(naturalRowHeights[rowIndex] * scale)
            guard rowHeight >= 1 else { return nil }

            let horizontalSpacing = resolvedSpacing(
                spacing,
                itemCount: row.count,
                availableLength: canvasSize.width
            )
            let widths = row.map { floor($0.aspectRatio * rowHeight) }
            guard widths.allSatisfy({ $0 >= 1 }) else { return nil }

            let rowWidth = widths.reduce(CGFloat.zero, +) +
                horizontalSpacing * CGFloat(max(0, row.count - 1))
            guard rowWidth <= canvasSize.width + 0.0001 else { return nil }

            rowLayouts.append((row, rowHeight, widths, horizontalSpacing, rowWidth))
        }

        let laidOutHeight = rowLayouts.reduce(CGFloat.zero) { $0 + $1.height } +
            verticalSpacing * CGFloat(max(0, rowLayouts.count - 1))
        guard laidOutHeight <= canvasSize.height + 0.0001 else { return nil }

        var placements: [Placement] = []
        placements.reserveCapacity(rows.reduce(0) { $0 + $1.count })

        var y = floor((canvasSize.height - laidOutHeight) * 0.5)
        for rowLayout in rowLayouts {
            var x = floor((canvasSize.width - rowLayout.width) * 0.5)
            for (index, window) in rowLayout.windows.enumerated() {
                let destinationRect = CGRect(
                    x: x,
                    y: y,
                    width: rowLayout.widths[index],
                    height: rowLayout.height
                )
                placements.append(
                    Placement(
                        id: window.id,
                        sourceRect: window.sourceRect,
                        destinationRect: destinationRect,
                        normalizedDestinationRect: normalizedRect(
                            destinationRect,
                            canvasSize: canvasSize
                        )
                    )
                )
                x += rowLayout.widths[index] + rowLayout.spacing
            }
            y += rowLayout.height + verticalSpacing
        }

        let contentRect = placements.reduce(CGRect.null) { partialResult, placement in
            partialResult.isNull
                ? placement.destinationRect
                : partialResult.union(placement.destinationRect)
        }

        return Candidate(
            result: Result(
                canvasSize: canvasSize,
                contentRect: contentRect.isNull ? .zero : contentRect.standardized,
                placements: placements
            ),
            usedArea: placements.reduce(CGFloat.zero) {
                $0 + $1.destinationRect.width * $1.destinationRect.height
            },
            rowCount: rows.count
        )
    }

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

    private static func isLowerPriority(_ lhs: Candidate, than rhs: Candidate) -> Bool {
        let areaDelta = lhs.usedArea - rhs.usedArea
        if abs(areaDelta) > 0.5 {
            return lhs.usedArea < rhs.usedArea
        }

        let lhsContentArea = lhs.result.contentRect.width * lhs.result.contentRect.height
        let rhsContentArea = rhs.result.contentRect.width * rhs.result.contentRect.height
        let contentDelta = lhsContentArea - rhsContentArea
        if abs(contentDelta) > 0.5 {
            return lhsContentArea < rhsContentArea
        }

        if lhs.rowCount != rhs.rowCount {
            return lhs.rowCount > rhs.rowCount
        }

        return false
    }

    private static func normalizedRect(
        _ rect: CGRect,
        canvasSize: CGSize
    ) -> CGRect {
        guard canvasSize.width > 0, canvasSize.height > 0 else { return .zero }
        return CGRect(
            x: rect.minX / canvasSize.width,
            y: rect.minY / canvasSize.height,
            width: rect.width / canvasSize.width,
            height: rect.height / canvasSize.height
        )
    }

    private static func resolvedSpacing(
        _ spacing: CGFloat,
        itemCount: Int,
        availableLength: CGFloat
    ) -> CGFloat {
        guard itemCount > 1, spacing > 0, spacing.isFinite, availableLength > 0 else { return 0 }
        let maximumSpacing = max(0, (availableLength - CGFloat(itemCount)) / CGFloat(itemCount - 1))
        return floor(min(spacing, maximumSpacing))
    }

    private static func normalizedCanvasSize(_ size: CGSize) -> CGSize {
        guard size.width.isFinite,
              size.height.isFinite,
              size.width > 0,
              size.height > 0 else {
            return .zero
        }
        return CGSize(width: floor(size.width), height: floor(size.height))
    }

    private static func normalizedSpacing(_ spacing: CGFloat) -> CGFloat {
        guard spacing.isFinite, spacing > 0 else { return 0 }
        return floor(spacing)
    }
}
#endif
