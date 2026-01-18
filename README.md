# MirageKit

MirageKit is a window and desktop streaming framework for Apple platforms. It provides a macOS host service for capturing windows or virtual displays and a client service for discovering hosts, receiving low‑latency video over UDP, and forwarding input back to the host. SwiftUI views are included for rendering streams with Metal on macOS, iOS, and visionOS.

> ⚠️ MirageKit is still in active development and may introduce breaking API updates.

## Features

- Window, app, and full desktop streaming from macOS hosts
- Bonjour discovery with TCP control + UDP video transport
- Peer-to-peer connections over AWDL
- Preset-based quality profiles and encoder configuration helpers
- Input forwarding (mouse, keyboard, scroll, gestures)
- SwiftUI stream view for macOS, iOS, and visionOS
- Session store + streaming content view for UI state
- Host window + input controllers for macOS integration
- Virtual display capture for pixel‑perfect rendering
- Remote session state + unlock support
- Menu bar passthrough and app‑centric streaming utilities
- Built-in trust store and app preference helpers

## Requirements

- macOS 26+ for host streaming (ScreenCaptureKit)
- iOS 26+ / visionOS 26+ for client streaming
- Swift 6.2+

## Installation

Add MirageKit as a Swift Package Manager dependency.

```swift
// Package.swift
.package(url: "https://github.com/EthanLipnik/MirageKit.git", from: "0.0.1"),
```

Then add `MirageKit` to the relevant target dependencies.

## Quick Start

### Host (macOS)

```swift
import MirageKit

@MainActor
final class HostController: MirageHostDelegate {
    private let hostService = MirageHostService()

    init() {
        hostService.delegate = self
    }

    func start() async throws {
        try await hostService.start()
    }

    func hostService(_ service: MirageHostService, shouldAllowClient client: MirageConnectedClient, toStreamWindow window: MirageWindow) -> Bool {
        true
    }
}
```

### Client (iOS/macOS/visionOS)

```swift
import MirageKit

@MainActor
final class ClientController: MirageClientDelegate {
    let clientService = MirageClientService()

    init() {
        clientService.delegate = self
    }

    func connect(to host: MirageHost) async throws {
        try await clientService.connect(to: host)
        try await clientService.requestWindowList()
    }

    func clientService(_ service: MirageClientService, didDecodeFrame pixelBuffer: CVPixelBuffer, forStream streamID: StreamID, contentRect: CGRect) {
        MirageFrameCache.shared.store(pixelBuffer, contentRect: contentRect, for: streamID)
    }
}
```

### SwiftUI Stream View

```swift
import MirageKit
import SwiftUI

struct StreamView: View {
    let streamID: StreamID
    @State private var latestFrame: CVPixelBuffer?
    @State private var contentRect: CGRect = .zero

    var body: some View {
        MirageStreamViewRepresentable(
            streamID: streamID,
            latestFrame: $latestFrame,
            contentRect: contentRect,
            onInputEvent: { event in
                // Forward event to MirageClientService
            },
            onDrawableSizeChanged: { size in
                // Use to request updated capture resolution
            }
        )
    }
}
```

MirageKit also includes a higher-level content view that wires input, focus, and
resize logic to a `MirageClientSessionStore`:

```swift
let sessionStore = MirageClientSessionStore()
let clientService = MirageClientService(sessionStore: sessionStore)

MirageStreamContentView(
    session: session,
    sessionStore: sessionStore,
    clientService: clientService,
    isDesktopStream: false
)
```

## How It Works

- Hosts advertise via Bonjour using `_mirage._tcp` and accept TCP control connections.
- Video payloads stream over UDP; clients register stream IDs to receive data.
- The host can create a shared virtual display sized to the client’s display for 1:1 pixels.
- Session state updates allow remote unlock flows (login screen vs locked session).
- Menu bar passthrough enables clients to render native menu structures and send actions back.

## Architecture

For a deeper dive into modules and data flows, see `Architecture.md`.

## Configuration

### Quality Presets

`MirageQualityPreset` provides ready-made profiles that map to bitrate caps and encoder quality for 60/120Hz targets.

- `.ultra` / `.high`: higher bitrate and quality for 60/120Hz targets
- `.medium`: balanced preset with higher caps at 120Hz
- `.low`: low-bandwidth preset with stronger compression at 120Hz
- `.lowLatency`: text apps with aggressive frame skipping

Each preset can be overridden per stream with `maxBitrate`, `keyFrameInterval`, and `keyframeQuality` (encoder quality for all frames) when starting a stream.

### Encoder Settings

`MirageEncoderConfiguration` lets you control codec, bitrate, frame rate, encoder quality, and color space.

- Use `.highQuality`, `.balanced`, or `.lowLatency` presets.
- Use `withOverrides` or `withMaxBitrate` to apply client-specific limits.
- Use `withTargetFrameRate` to request 60/120fps based on display capabilities.
- `keyframeQuality` sets encoder quality for all frames and maps to QP bounds when supported.

### Networking

`MirageNetworkConfiguration` defines discovery and transport behavior.

- `serviceType` is used for Bonjour discovery.
- `controlPort` (TCP) and `dataPort` (UDP) support explicit or auto-assigned ports (defaults: 9847/9848).
- `enablePeerToPeer` turns on AWDL peer-to-peer discovery and connections.
- `maxPacketSize` controls UDP payload sizing (default stays within IPv6 MTU).

### Streaming Modes

- Window streaming captures a specific window using ScreenCaptureKit.
- Desktop streaming mirrors a virtual display and supports display-sized capture.
- App streaming groups windows by bundle identifier and tracks newly spawned windows.

### Input + UI

- Input events are forwarded via `MirageInputEvent` types (mouse, key, scroll, magnify, rotate).
- `MirageStreamViewRepresentable` renders streams with Metal and exposes drawable size callbacks for resolution sync.
- `MirageStreamContentView` + `MirageClientSessionStore` coordinate input, focus, and resize UI.
- The host uses `MirageHostDelegate` and the client uses `MirageClientDelegate` for approvals and state updates.

## Permissions

The macOS host uses ScreenCaptureKit and may require Screen Recording permission. To forward input or activate windows, the host app may also need Accessibility permission. Clients should have Local Network permission for Bonjour discovery.

## Contributing

Contributions are welcome. Most of this framework was built with agentic coding tools (Claude Code and Codex). Using them is fine as long as you understand and can explain the updates you submit.

## Testing

```bash
swift test
```

## License

MirageKit is licensed under the PolyForm Shield 1.0.0 license. Use, modification, and distribution are allowed for non-competing products; providing products that compete with Mirage or other dedicated remote window/desktop/secondary display/drawing-tablet streaming applications and services is prohibited. See `LICENSE`.
