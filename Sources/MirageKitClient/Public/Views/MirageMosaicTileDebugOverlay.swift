//
//  MirageMosaicTileDebugOverlay.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 6/6/26.
//

import MirageMedia
import SwiftUI

public struct MirageMosaicTileDebugOverlayModel: Equatable, Sendable {
    public struct Tile: Equatable, Identifiable, Sendable {
        public let id: String
        public let label: String
        public let rect: CGRect
        public let sourceRect: MiragePixelRect
        public let semanticClass: MirageMosaicSemanticClass
        public let priority: MirageMosaicTilePriority
    }

    public let contentRect: CGRect
    public let epochLabel: String
    public let tiles: [Tile]

    public static func model(
        tilePlan: MirageMosaicTilePlan?,
        containerSize: CGSize
    ) -> MirageMosaicTileDebugOverlayModel {
        let safeContainer = CGSize(
            width: max(1, containerSize.width),
            height: max(1, containerSize.height)
        )
        let plan = tilePlan ?? MirageMosaicTilePlan.fixedGrid(
            logicalSize: MiragePixelSize(
                width: Int(safeContainer.width.rounded(.toNearestOrAwayFromZero)),
                height: Int(safeContainer.height.rounded(.toNearestOrAwayFromZero))
            ),
            columns: 3,
            rows: 3,
            codec: .hevc
        )
        guard !plan.logicalSize.isEmpty else {
            return MirageMosaicTileDebugOverlayModel(contentRect: .zero, epochLabel: "Mosaic", tiles: [])
        }

        let scale = min(
            safeContainer.width / CGFloat(plan.logicalSize.width),
            safeContainer.height / CGFloat(plan.logicalSize.height)
        )
        let contentSize = CGSize(
            width: CGFloat(plan.logicalSize.width) * scale,
            height: CGFloat(plan.logicalSize.height) * scale
        )
        let origin = CGPoint(
            x: (safeContainer.width - contentSize.width) / 2,
            y: (safeContainer.height - contentSize.height) / 2
        )
        let contentRect = CGRect(origin: origin, size: contentSize)
        let tiles = plan.tiles.map { tile in
            Tile(
                id: tile.id.rawValue,
                label: "\(tile.id.rawValue) \(tile.semanticClass.rawValue)",
                rect: CGRect(
                    x: origin.x + CGFloat(tile.presentationRect.x) * scale,
                    y: origin.y + CGFloat(tile.presentationRect.y) * scale,
                    width: CGFloat(tile.presentationRect.width) * scale,
                    height: CGFloat(tile.presentationRect.height) * scale
                ),
                sourceRect: tile.sourceRect,
                semanticClass: tile.semanticClass,
                priority: tile.priority
            )
        }
        return MirageMosaicTileDebugOverlayModel(
            contentRect: contentRect,
            epochLabel: "Mosaic e\(plan.epoch)",
            tiles: tiles
        )
    }
}

public struct MirageMosaicTileDebugOverlay: View {
    private let tilePlan: MirageMosaicTilePlan?

    public init(tilePlan: MirageMosaicTilePlan? = nil) {
        self.tilePlan = tilePlan
    }

    public var body: some View {
        GeometryReader { proxy in
            let model = MirageMosaicTileDebugOverlayModel.model(
                tilePlan: tilePlan,
                containerSize: proxy.size
            )

            ZStack(alignment: .topLeading) {
                Path(model.contentRect)
                    .stroke(.white.opacity(0.65), lineWidth: 1)
                Text(model.epochLabel)
                    .font(.caption2.monospaced())
                    .padding(.horizontal, 5)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.68), in: RoundedRectangle(cornerRadius: 3))
                    .foregroundStyle(.white)
                    .position(x: model.contentRect.minX + 42, y: model.contentRect.minY + 13)

                ForEach(model.tiles) { tile in
                    Path(tile.rect)
                        .stroke(color(for: tile.semanticClass), lineWidth: 1.5)
                    Text(tile.label)
                        .font(.caption2.monospaced())
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 3))
                        .foregroundStyle(.white)
                        .position(
                            x: min(tile.rect.maxX - 42, tile.rect.minX + 54),
                            y: tile.rect.minY + 12
                        )
                }
            }
            .allowsHitTesting(false)
        }
        .allowsHitTesting(false)
    }

    private func color(for semanticClass: MirageMosaicSemanticClass) -> Color {
        switch semanticClass {
        case .scrollView,
             .textViewport:
            .green
        case .menuBar,
             .dock,
             .toolbar,
             .sidebar,
             .chromeAtlas:
            .cyan
        case .focusedWindow:
            .yellow
        case .popover,
             .sheet,
             .menu:
            .orange
        case .canvas,
             .video:
            .purple
        case .background:
            .gray
        case .unknown,
             .gridFallback:
            .red
        }
    }
}
