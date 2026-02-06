//
//  MirageQualityProbeScene.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/4/26.
//
//  SwiftUI probe scene for automatic quality testing.
//

import AppKit
import CoreGraphics
import SwiftUI
import MirageKit

#if os(macOS)
@MainActor
final class MirageQualityProbeWindow {
    private let displayID: CGDirectDisplayID
    private let spaceID: CGSSpaceID
    private let bounds: CGRect
    private let window: NSWindow

    init(displayID: CGDirectDisplayID, spaceID: CGSSpaceID, bounds: CGRect) {
        self.displayID = displayID
        self.spaceID = spaceID
        self.bounds = bounds
        let resolvedBounds = bounds.width > 0 && bounds.height > 0 ? bounds : CGRect(origin: .zero, size: .init(width: 1280, height: 720))
        let window = NSWindow(
            contentRect: resolvedBounds,
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isOpaque = true
        window.backgroundColor = .black
        window.hasShadow = false
        window.level = .normal
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.stationary, .ignoresCycle, .fullScreenAuxiliary]

        let hostingView = NSHostingView(rootView: QualityProbeSceneView())
        hostingView.frame = CGRect(origin: .zero, size: resolvedBounds.size)
        hostingView.autoresizingMask = [.width, .height]
        window.contentView = hostingView

        let windowID = CGWindowID(window.windowNumber)
        CGSWindowSpaceBridge.moveWindowToSpace(windowID, spaceID: spaceID)

        self.window = window
    }

    func start() {
        let windowID = CGWindowID(window.windowNumber)
        CGSWindowSpaceBridge.moveWindowToSpace(windowID, spaceID: spaceID)
        let didActivateSpace = CGSWindowSpaceBridge.setCurrentSpaceForDisplay(displayID, spaceID: spaceID)
        if !didActivateSpace {
            MirageLogger.host("Quality probe window failed to activate space \(spaceID) for display \(displayID)")
        }
        if !CGSWindowSpaceBridge.moveWindow(windowID, to: bounds.origin) {
            MirageLogger.host("Quality probe window failed to move to display origin \(bounds.origin)")
        }
        window.setFrame(bounds, display: false)
        window.orderFrontRegardless()
    }

    func stop() {
        window.orderOut(nil)
    }
}

private struct QualityProbeSceneView: View {
    var body: some View {
        TimelineView(.animation) { context in
            let phase = context.date.timeIntervalSinceReferenceDate
            ZStack {
                ProbeBackgroundView(phase: phase)
                HStack {
                    ProbeSidebarView(phase: phase)
                    ProbeMainView(phase: phase)
                    ProbeInspectorView(phase: phase)
                }
                .padding()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct ProbeBackgroundView: View {
    let phase: Double

    var body: some View {
        Canvas { context, size in
            let time = phase * 0.35
            let gradient = Gradient(colors: [
                Color(red: 0.10, green: 0.12, blue: 0.18),
                Color(red: 0.08, green: 0.08, blue: 0.14),
            ])
            context.fill(
                Path(CGRect(origin: .zero, size: size)),
                with: .linearGradient(gradient, startPoint: .zero, endPoint: CGPoint(x: size.width, y: size.height))
            )

            let orbit = min(size.width, size.height) * 0.25
            let center = CGPoint(x: size.width * 0.65, y: size.height * 0.35)
            for index in 0 ..< 4 {
                let offset = Double(index) * 0.6
                let angle = time + offset
                let point = CGPoint(
                    x: center.x + cos(angle) * orbit,
                    y: center.y + sin(angle * 1.2) * orbit
                )
                let radius = min(size.width, size.height) * (0.06 + Double(index) * 0.02)
                var circle = Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
                circle = circle.applying(.init(scaleX: 1.2, y: 0.9))
                context.fill(circle, with: .color(Color.white.opacity(0.06)))
            }
        }
        .ignoresSafeArea()
    }
}

private struct ProbeSidebarView: View {
    let phase: Double

    var body: some View {
        VStack {
            ProbeTitleCard()
            ProbeMetricCard(title: "Throughput Targets") {
                VStack(alignment: .leading) {
                    ProbeMetricRow(label: "Encoder", value: "HEVC Main10")
                    ProbeMetricRow(label: "Target FPS", value: "60")
                    ProbeMetricRow(label: "Network", value: "Adaptive")
                }
            }
            ProbeMetricCard(title: "Transport") {
                VStack(alignment: .leading) {
                    ProgressView(value: progressValue)
                    ProbeMetricRow(label: "Loss Budget", value: "< 2%")
                    ProbeMetricRow(label: "Headroom", value: "5%")
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var progressValue: Double {
        0.5 + sin(phase * 0.8) * 0.5
    }
}

private struct ProbeMainView: View {
    let phase: Double

    var body: some View {
        VStack {
            ProbeHeroCard(phase: phase)
            ProbeMetricCard(title: "Signal Mesh") {
                ProbeDetailGridView(phase: phase)
                    .frame(height: 180)
            }
            ProbeMetricCard(title: "Visual Complexity") {
                HStack {
                    ProbeCardTile(title: "Layers", value: "14")
                    ProbeCardTile(title: "Shadows", value: "7")
                    ProbeCardTile(title: "Motion", value: "Live")
                }
            }
            ProbeMetricCard(title: "Waveform") {
                ProbeWaveformView(phase: phase)
                    .frame(height: 140)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

private struct ProbeInspectorView: View {
    let phase: Double

    var body: some View {
        VStack {
            ProbeMetricCard(title: "Encoder Load") {
                VStack(alignment: .leading) {
                    ProbeMetricRow(label: "QP Range", value: "Auto")
                    ProbeMetricRow(label: "Keyframe", value: "2s")
                    ProbeMetricRow(label: "Color", value: "P3")
                }
            }
            ProbeMetricCard(title: "Scene Diagnostics") {
                VStack(alignment: .leading) {
                    ProbeMetricRow(label: "GPU", value: "Active")
                    ProbeMetricRow(label: "CPU", value: "Stable")
                    ProbeMetricRow(label: "Frame Pacing", value: pacingText)
                }
            }
            ProbeMetricCard(title: "Focus Regions") {
                VStack(alignment: .leading) {
                    ProbeMetricRow(label: "Primary", value: "Center")
                    ProbeMetricRow(label: "Secondary", value: "Sidebar")
                    ProbeMetricRow(label: "Detail", value: "Inspector")
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var pacingText: String {
        phase.truncatingRemainder(dividingBy: 4.0) > 2.0 ? "Synced" : "Adaptive"
    }
}

private struct ProbeTitleCard: View {
    var body: some View {
        VStack(alignment: .leading) {
            Label("Mirage Quality Probe", systemImage: "waveform.path.ecg")
                .font(.title3)
                .bold()
            Text("Synthetic UI workload with live animation layers.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.ultraThinMaterial)
        .clipShape(.rect(cornerRadius: 18))
    }
}

private struct ProbeHeroCard: View {
    let phase: Double

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 22)
                .fill(Color.white.opacity(0.08))
            VStack(alignment: .leading) {
                Text("Scene Preview")
                    .font(.headline)
                Text("Animating depth, gradients, and timing.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack {
                    ProgressView(value: indicatorValue)
                    Text("Live")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
        }
        .clipShape(.rect(cornerRadius: 22))
    }

    private var indicatorValue: Double {
        0.5 + sin(phase) * 0.5
    }
}

private struct ProbeMetricCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading) {
            Text(title)
                .font(.headline)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color.white.opacity(0.06))
        .clipShape(.rect(cornerRadius: 18))
    }
}

private struct ProbeMetricRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text(value)
                .bold()
        }
        .font(.caption)
    }
}

private struct ProbeCardTile: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color.white.opacity(0.05))
        .clipShape(.rect(cornerRadius: 16))
    }
}

private struct ProbeWaveformView: View {
    let phase: Double

    var body: some View {
        Canvas { context, size in
            let amplitude = size.height * 0.35
            let midY = size.height / 2
            let step = max(1.0, size.width / 48.0)
            var path = Path()
            var x: CGFloat = 0
            while x <= size.width {
                let progress = Double(x / size.width)
                let angle = progress * 8.0 + phase * 1.6
                let y = midY + CGFloat(sin(angle) * cos(angle * 0.5)) * amplitude
                if x == 0 {
                    path.move(to: CGPoint(x: x, y: y))
                } else {
                    path.addLine(to: CGPoint(x: x, y: y))
                }
                x += step
            }
            context.stroke(path, with: .color(Color.white.opacity(0.8)), lineWidth: 2)
        }
        .background(Color.white.opacity(0.04))
        .clipShape(.rect(cornerRadius: 16))
    }
}

private struct ProbeDetailGridView: View {
    let phase: Double

    var body: some View {
        Canvas { context, size in
            let columns = 36
            let rows = 20
            let cellWidth = size.width / CGFloat(columns)
            let cellHeight = size.height / CGFloat(rows)
            let time = phase * 0.9

            for row in 0 ..< rows {
                for column in 0 ..< columns {
                    let seed = Double((row * 127 + column * 197) % 1024) / 1024.0
                    let wave = sin(time + seed * 6.283) * cos(time * 0.6 + seed * 4.1)
                    let brightness = 0.25 + (0.35 * (0.5 + 0.5 * wave))
                    let hue = (seed + time * 0.03).truncatingRemainder(dividingBy: 1.0)
                    let rect = CGRect(
                        x: CGFloat(column) * cellWidth,
                        y: CGFloat(row) * cellHeight,
                        width: cellWidth,
                        height: cellHeight
                    )
                    context.fill(
                        Path(rect),
                        with: .color(Color(hue: hue, saturation: 0.6, brightness: brightness))
                    )
                }
            }
        }
        .background(Color.white.opacity(0.03))
        .clipShape(.rect(cornerRadius: 16))
    }
}
#endif
