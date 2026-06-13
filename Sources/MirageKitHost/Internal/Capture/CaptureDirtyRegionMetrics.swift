//
//  CaptureDirtyRegionMetrics.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 6/12/26.
//

import CoreGraphics
import Foundation

#if os(macOS)
enum CaptureDirtyRegionMetrics {
    static func dirtyPercentage(
        dirtyRectsValue: Any?,
        contentRect: CGRect,
        fullRect: CGRect,
        isIdleFrame: Bool
    ) -> Float {
        if isIdleFrame { return 0 }
        guard let dirtyRects = dirtyRects(from: dirtyRectsValue) else {
            return fullRect.width > 0 && fullRect.height > 0 ? 100 : 0
        }
        guard !dirtyRects.isEmpty else { return 0 }

        let bounds = dirtyBounds(contentRect: contentRect, fullRect: fullRect)
        guard bounds.width > 0, bounds.height > 0 else { return 0 }

        let clippedRects = dirtyRects.compactMap { rect -> CGRect? in
            let clipped = rect.standardized.intersection(bounds).intersection(fullRect)
            guard clipped.width > 0, clipped.height > 0 else { return nil }
            return clipped
        }
        guard !clippedRects.isEmpty else { return 0 }

        let dirtyArea = unionArea(of: clippedRects)
        let totalArea = bounds.width * bounds.height
        guard totalArea > 0 else { return 0 }
        return Float(max(0, min(100, dirtyArea / totalArea * 100)))
    }

    private static func dirtyBounds(contentRect: CGRect, fullRect: CGRect) -> CGRect {
        let standardizedContent = contentRect.standardized
        let standardizedFull = fullRect.standardized
        guard standardizedContent.width > 0, standardizedContent.height > 0 else {
            return standardizedFull
        }
        let clipped = standardizedContent.intersection(standardizedFull)
        return clipped.isNull ? standardizedFull : clipped
    }

    private static func dirtyRects(from value: Any?) -> [CGRect]? {
        guard let value else { return nil }
        if let rects = value as? [CGRect] {
            return rects
        }
        if let rect = value as? CGRect {
            return [rect]
        }
        if let array = value as? NSArray {
            return array.compactMap(rect(from:))
        }
        return rect(from: value).map { [$0] }
    }

    private static func rect(from value: Any) -> CGRect? {
        if let rect = value as? CGRect {
            return rect
        }
        if let value = value as? NSValue {
            return value.rectValue
        }
        if let dictionary = value as? NSDictionary,
           let rect = CGRect(dictionaryRepresentation: dictionary as CFDictionary) {
            return rect
        }
        return nil
    }

    private static func unionArea(of rects: [CGRect]) -> CGFloat {
        let xEdges = Set(rects.flatMap { [$0.minX, $0.maxX] }).sorted()
        guard xEdges.count > 1 else { return 0 }

        var area: CGFloat = 0
        for index in 0..<(xEdges.count - 1) {
            let minX = xEdges[index]
            let maxX = xEdges[index + 1]
            let width = maxX - minX
            guard width > 0 else { continue }

            var yRanges: [(CGFloat, CGFloat)] = []
            for rect in rects where rect.minX < maxX && rect.maxX > minX {
                yRanges.append((rect.minY, rect.maxY))
            }
            guard !yRanges.isEmpty else { continue }

            yRanges.sort { $0.0 < $1.0 }
            var coveredHeight: CGFloat = 0
            var currentMin = yRanges[0].0
            var currentMax = yRanges[0].1
            for range in yRanges.dropFirst() {
                if range.0 <= currentMax {
                    currentMax = max(currentMax, range.1)
                } else {
                    coveredHeight += max(0, currentMax - currentMin)
                    currentMin = range.0
                    currentMax = range.1
                }
            }
            coveredHeight += max(0, currentMax - currentMin)
            area += width * coveredHeight
        }
        return area
    }
}
#endif
